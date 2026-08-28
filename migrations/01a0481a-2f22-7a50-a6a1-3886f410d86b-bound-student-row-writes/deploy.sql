-- Bound how many rows one student or TA request may change (issue #346).
--
-- The control this replaces was `Prefer: handling=strict, max-affected=1`,
-- sent by mcpapp on a PATCH or DELETE through the escape hatch (issue #337).
-- That is a *request preference*: the server cannot require it, so it bound
-- only the one client we wrote. A student with a personal access token and
-- curl simply omits it. Worse, it is verb-shaped, and student writes do not
-- primarily arrive as PATCH -- they arrive as a batch upsert POST. Verified on
-- the dev stack with an ordinary student token: one
--
--     POST /rest/assignment_field_submissions
--     Prefer: return=representation, resolution=merge-duplicates
--     [ {...}, {...} ]
--
-- wrote two rows and no cap applied, because PostgREST turns that into
-- INSERT ... ON CONFLICT DO UPDATE -- an update of many rows wearing a POST.
-- That also falsifies the comment this migration removes from
-- mcpapp/escape_hatch.go, which claimed POST is "uncapped by construction: an
-- insert names its target in the body". True of a single-object insert, false
-- of a JSON array upsert.
--
-- So the bound moves into PostgreSQL, as statement-level AFTER triggers with
-- transition tables. A trigger counts the rows a statement actually affected,
-- whatever verb delivered it and whichever client sent it: MCP, a personal
-- access token with curl, the Elm client, psql. Raising from the trigger rolls
-- the statement back, including any audit rows its row-level triggers wrote.
--
-- What this bounds is *breadth*, not intent. Sequential small writes still
-- work; the boundary for whether a write should happen at all remains the
-- `submissions:write` scope (issue #317). What it removes is the case where
-- one unfiltered statement -- one prompt injection, one careless script --
-- reaches every row RLS admits, which for a team submission is other people's
-- work.

-- The default bound, and the only place the number 64 is written. It is a
-- schema constant, changed by migration and by nothing else: not an
-- environment variable and not a request header, because a bound a client can
-- choose is not a bound. 64 clears every legitimate save with room to spare --
-- the Elm client's multi-field submit writes one row per field and Fall 2026
-- assignments carry at most five, and a TA marking a ~60 person roster in one
-- statement fits -- while staying far below "every row RLS permits".
CREATE FUNCTION data.request_row_bound_default() RETURNS integer
    IMMUTABLE
    LANGUAGE sql
    RETURN 64;

COMMENT ON FUNCTION data.request_row_bound_default() IS
    'Rows one student or TA request may affect in one table, unless a trigger names a stricter bound. Issue #346.';

-- The per-request tally, as a transaction-local GUC holding a JSON object
-- keyed by table name. It has to accumulate across trigger firings rather than
-- be checked once per firing, because INSERT ... ON CONFLICT DO UPDATE fires
-- the statement-level UPDATE trigger *and* the statement-level INSERT trigger
-- for the same statement. Checking each firing against the bound separately
-- would let an upsert affect twice the bound, which is the shape the Elm
-- client and every batch write through PostgREST actually take.
--
-- Keyed by table, so "64 rows of assignment_field_submission" does not consume
-- the budget of a different table with a different bound.
--
-- This is a blast-radius control, not a privilege boundary: a session with an
-- arbitrary SQL channel can reset the GUC itself. PostgREST offers no such
-- channel -- one request is one statement or one call to a function we wrote,
-- and this function lives in `request`, which PostgREST does not expose -- so
-- the bound holds on every path a student can actually reach.
CREATE FUNCTION request.reset_row_bound_counters() RETURNS void
    VOLATILE
    LANGUAGE sql
    SET search_path = pg_catalog, pg_temp
    BEGIN ATOMIC
        SELECT set_config('yeluke.rows_affected', '', true);
    END;

COMMENT ON FUNCTION request.reset_row_bound_counters() IS
    'Start a fresh per-request row budget. Called by api.check_request_jwt at the top of every PostgREST request. Issue #346.';

-- The bound itself. Attached AFTER ... FOR EACH STATEMENT so it sees the rows
-- that survived row-level security and the BEFORE row triggers -- the rows
-- really written -- rather than the rows the client asked for.
-- SECURITY DEFINER because the trigger runs as the acting role, and `student`
-- has no USAGE on schema `data` -- it reaches its rows only through the api
-- views. A bound that a student's own privileges have to be sufficient to
-- evaluate is not a bound. The search_path is pinned, there is no dynamic SQL,
-- and the only things this reads are its own transition table and two GUCs.
CREATE FUNCTION data.enforce_request_row_bound() RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, data, request, pg_temp
    AS $$
DECLARE
    acting_role text;
    row_limit integer;
    affected bigint;
    tally bigint;
    counters jsonb;
    counter_key text;
BEGIN
    -- Applies to student and TA credentials only. Faculty, the faculty import
    -- RPCs, and a migration or admin session with no request role at all are
    -- exempt: sync_meetings deletes every stale meeting in one statement and
    -- must keep doing so.
    --
    -- request.user_role() is the only reader used here on purpose. It resolves
    -- both the individual claim GUCs (request.jwt.claim.role) and the JSON
    -- claims GUC (request.jwt.claims), and the two are not interchangeable in
    -- practice: the database test suite sets the former directly while real
    -- PostgREST traffic arrives with the latter (issue #345). A check that
    -- read only one of them would pass its tests and not bind production, or
    -- the reverse.
    acting_role := request.user_role();
    IF acting_role IS DISTINCT FROM 'student' AND acting_role IS DISTINCT FROM 'ta' THEN
        RETURN NULL;
    END IF;

    row_limit := coalesce(nullif(TG_ARGV[0], '')::integer, data.request_row_bound_default());

    IF TG_OP = 'DELETE' THEN
        SELECT count(*) INTO affected FROM bounded_old_rows;
    ELSE
        SELECT count(*) INTO affected FROM bounded_new_rows;
    END IF;

    counter_key := TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
    counters := coalesce(nullif(current_setting('yeluke.rows_affected', true), '')::jsonb, '{}'::jsonb);
    tally := coalesce((counters ->> counter_key)::bigint, 0) + affected;
    PERFORM set_config(
        'yeluke.rows_affected',
        jsonb_set(counters, ARRAY[counter_key], to_jsonb(tally))::text,
        true
    );

    IF tally > row_limit THEN
        -- PT400 is PostgREST's convention for "answer this with HTTP 400", the
        -- same status PostgREST itself uses for an exceeded max-affected.
        RAISE EXCEPTION
            'this request would change % rows of %; a % may change at most % rows of that table in one request',
            tally, counter_key, acting_role, row_limit
            USING ERRCODE = 'PT400',
                  DETAIL = format(
                      'statement rows: %s, request total: %s. Nothing was changed: the statement was rolled back.',
                      affected, tally),
                  HINT = 'Narrow the filter so the statement identifies the rows you meant, or send the change as several smaller requests.';
    END IF;

    RETURN NULL;
END;
$$;

ALTER FUNCTION data.enforce_request_row_bound() OWNER TO yelukerest_migrator;

COMMENT ON FUNCTION data.enforce_request_row_bound() IS
    'Statement-level bound on rows one student or TA request may affect in one table. Issue #346.';

-- assignment_field_submission carries a second rule: every row one statement
-- affects must belong to the same assignment_submission. That is the logical
-- unit of the Elm client's save -- one submission, one row per field -- and it
-- is what makes a broad statement fail loudly instead of quietly rewriting a
-- term's worth of a team's work while staying inside the row bound.
CREATE FUNCTION data.enforce_single_assignment_submission() RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, data, request, pg_temp
    AS $$
DECLARE
    acting_role text;
    parents bigint;
BEGIN
    acting_role := request.user_role();
    IF acting_role IS DISTINCT FROM 'student' AND acting_role IS DISTINCT FROM 'ta' THEN
        RETURN NULL;
    END IF;

    IF TG_OP = 'DELETE' THEN
        SELECT count(DISTINCT assignment_submission_id) INTO parents FROM bounded_old_rows;
    ELSE
        SELECT count(DISTINCT assignment_submission_id) INTO parents FROM bounded_new_rows;
    END IF;

    IF parents > 1 THEN
        RAISE EXCEPTION
            'this statement changes assignment field submissions belonging to % different assignment submissions; one statement may change only one',
            parents
            USING ERRCODE = 'PT400',
                  DETAIL = 'Nothing was changed: the statement was rolled back.',
                  HINT = 'Write one assignment submission at a time: filter on a single assignment_submission_id, or send one request per assignment.';
    END IF;

    RETURN NULL;
END;
$$;

ALTER FUNCTION data.enforce_single_assignment_submission() OWNER TO yelukerest_migrator;

COMMENT ON FUNCTION data.enforce_single_assignment_submission() IS
    'One statement may only touch assignment field submissions of a single assignment submission, for student and TA credentials. Issue #346.';

-- Triggers. Every base table a student or TA may write gets all three
-- operations, including operations nobody currently holds a grant for, so a
-- later migration that widens a grant does not silently widen the bound. The
-- verify script and tests/db/row-bound-coverage.sql both assert that
-- correspondence, so a new writable table cannot land without one.
--
-- Transition tables can only be declared on a single-event trigger, which is
-- why these are three triggers per table rather than one.

CREATE TRIGGER tg_assignment_field_submission_row_bound_insert
    AFTER INSERT ON data.assignment_field_submission
    REFERENCING NEW TABLE AS bounded_new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_request_row_bound();

CREATE TRIGGER tg_assignment_field_submission_row_bound_update
    AFTER UPDATE ON data.assignment_field_submission
    REFERENCING NEW TABLE AS bounded_new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_request_row_bound();

CREATE TRIGGER tg_assignment_field_submission_row_bound_delete
    AFTER DELETE ON data.assignment_field_submission
    REFERENCING OLD TABLE AS bounded_old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_request_row_bound();

CREATE TRIGGER tg_assignment_field_submission_single_parent_insert
    AFTER INSERT ON data.assignment_field_submission
    REFERENCING NEW TABLE AS bounded_new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_single_assignment_submission();

CREATE TRIGGER tg_assignment_field_submission_single_parent_update
    AFTER UPDATE ON data.assignment_field_submission
    REFERENCING NEW TABLE AS bounded_new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_single_assignment_submission();

CREATE TRIGGER tg_assignment_field_submission_single_parent_delete
    AFTER DELETE ON data.assignment_field_submission
    REFERENCING OLD TABLE AS bounded_old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_single_assignment_submission();

-- assignment_submission is bounded at 4 rather than 64. A submission is the
-- parent record for one assignment, and every path that creates one creates
-- exactly one: the Elm client posts a single object
-- (elmclient/src/elm/Assignments/Commands.elm), and a student clearing away an
-- empty submission deletes one. Nothing legitimate creates or deletes them in
-- bulk, so the bound is set just above the observed maximum -- four leaves room
-- for a client that batches a couple of assignments, and for a retry, while a
-- statement that sweeps the fifteen-odd submissions of a term is refused. The
-- gap between 1 and 4 costs nothing: a broad DELETE here is already narrow,
-- because the NO ACTION foreign keys from assignment_field_submission and
-- assignment_grade stop any submission holding content or a grade from being
-- deleted at all.
CREATE TRIGGER tg_assignment_submission_row_bound_insert
    AFTER INSERT ON data.assignment_submission
    REFERENCING NEW TABLE AS bounded_new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_request_row_bound('4');

CREATE TRIGGER tg_assignment_submission_row_bound_update
    AFTER UPDATE ON data.assignment_submission
    REFERENCING NEW TABLE AS bounded_new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_request_row_bound('4');

CREATE TRIGGER tg_assignment_submission_row_bound_delete
    AFTER DELETE ON data.assignment_submission
    REFERENCING OLD TABLE AS bounded_old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_request_row_bound('4');

-- engagement is writable by TAs only, and marking a whole section's attendance
-- in one statement is the ordinary use, so it keeps the default 64.
CREATE TRIGGER tg_engagement_row_bound_insert
    AFTER INSERT ON data.engagement
    REFERENCING NEW TABLE AS bounded_new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_request_row_bound();

CREATE TRIGGER tg_engagement_row_bound_update
    AFTER UPDATE ON data.engagement
    REFERENCING NEW TABLE AS bounded_new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_request_row_bound();

CREATE TRIGGER tg_engagement_row_bound_delete
    AFTER DELETE ON data.engagement
    REFERENCING OLD TABLE AS bounded_old_rows
    FOR EACH STATEMENT EXECUTE FUNCTION data.enforce_request_row_bound();

-- Start the budget at the top of every PostgREST request. This is the only
-- change to the hook: everything below it is the function as
-- 01a02545-enforce-scopes-on-writes left it.
--
-- It runs before the early return for anonymous, so every request starts from
-- zero whatever role it carries. Strictly this is belt and braces: the tally is
-- a transaction-local GUC and PostgREST gives each request its own transaction,
-- so it is discarded at the end of one anyway. What the explicit call buys is a
-- named place where a request begins -- which the database test suite needs,
-- because it plays out many requests inside a single transaction -- and a
-- budget that stays correct if two requests ever share a transaction.
--
-- Resetting per request rather than per statement is deliberate: a SECURITY
-- DEFINER function runs as its owner but does not erase the request claims, so
-- a multi-statement RPC still sees `student` and still spends one budget.
-- Wrapping a write in a function is therefore not a way around the bound.
CREATE OR REPLACE FUNCTION api.check_request_jwt() RETURNS void
STABLE
SECURITY DEFINER
LANGUAGE plpgsql
SET search_path = pg_catalog, api, settings, request, pg_temp
AS $$
DECLARE
    claims jsonb;
    claim_role text;
    claim_issuer text;
    expected_audience text;
    expected_subject text;
    audience_claim jsonb;
    audience_text text;
    subject_claim text;
    scopes_claim text;
    request_method text;
BEGIN
    -- A fresh row budget for this request (issue #346).
    PERFORM request.reset_row_bound_counters();

    claim_role := request.user_role();
    IF claim_role IS NULL OR claim_role = '' OR claim_role = 'anonymous' THEN
        RETURN;
    END IF;

    claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
    claim_issuer := request.jwt_claim('iss');
    IF claim_issuer IS DISTINCT FROM settings.get('jwt_issuer') THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt issuer';
    END IF;

    expected_audience := settings.get('jwt_audience');
    audience_claim := CASE WHEN claims IS NULL THEN NULL ELSE claims->'aud' END;
    audience_text := request.jwt_claim('aud');
    IF NOT (
        (jsonb_typeof(audience_claim) = 'string' AND audience_claim #>> '{}' = expected_audience)
        OR
        (jsonb_typeof(audience_claim) = 'array' AND audience_claim ? expected_audience)
        OR
        audience_text = expected_audience
    ) THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt audience';
    END IF;

    subject_claim := request.jwt_claim('sub');
    IF coalesce(subject_claim, '') = '' THEN
        RAISE insufficient_privilege USING MESSAGE = 'missing jwt subject';
    END IF;

    expected_subject := CASE
        WHEN claim_role = 'app' THEN 'app:' || coalesce(request.app_name(), '')
        ELSE 'user:' || coalesce(request.user_id_as_text(), '')
    END;
    IF subject_claim IS DISTINCT FROM expected_subject THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt subject';
    END IF;

    -- Scope enforcement for scope-carrying tokens (issue #317).
    --
    -- A JWT minted from a personal access token, or by mcpapp, carries a
    -- `scopes` claim. Until now nothing on the PostgREST path looked at it:
    -- mcpapp checked scopes for its own tool calls, but a token exchanged from
    -- a read-only personal access token could still PATCH a submission,
    -- because row-level security asks who you are and never what the token was
    -- allowed to do. Verified before this change: a read-only token PATCHed
    -- assignment_field_submissions and got a 200.
    --
    -- Tokens with no `scopes` claim -- the browser JWT from /auth/jwt, and the
    -- authapp/mcpapp service credentials -- are unaffected and keep the
    -- permissions their role gives them.
    --
    -- The rule matches what mcpapp already enforces for its escape hatch: read
    -- methods are free, everything else needs submissions:write. This also
    -- stops a read-only token calling create_user_api_token to mint itself a
    -- writable one, which would otherwise be a straightforward escalation.
    scopes_claim := request.jwt_claim('scopes');
    IF coalesce(scopes_claim, '') <> '' THEN
        request_method := upper(coalesce(current_setting('request.method', true), ''));
        -- An empty method means this is not a PostgREST request (a direct psql
        -- session, say), so there is nothing to gate.
        IF request_method <> '' AND request_method NOT IN ('GET', 'HEAD', 'OPTIONS') THEN
            IF position(' submissions:write ' in ' ' || scopes_claim || ' ') = 0 THEN
                RAISE insufficient_privilege
                    USING MESSAGE = 'this token is read-only: it lacks the submissions:write scope';
            END IF;
        END IF;
    END IF;
END;
$$;

ALTER FUNCTION api.check_request_jwt() OWNER TO yelukerest_migrator;
REVOKE ALL ON FUNCTION api.check_request_jwt() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.check_request_jwt() TO anonymous, student, ta, faculty, observer, app;

NOTIFY pgrst, 'reload schema';
