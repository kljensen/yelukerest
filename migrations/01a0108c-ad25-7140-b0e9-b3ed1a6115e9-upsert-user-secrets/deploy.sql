-- Bulk secret distribution (#303), plus the last #308 trigger holdout.
--
-- Contents:
--   #303  api.upsert_user_secrets, api.upsert_team_secrets, and the two data
--         schema helpers they share
--   #308  data.fill_user_secret_defaults, routed through data.touched_at like
--         the other eleven triggers already are
--   plus  admin_api_version 9
--
-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.

-- ---------------------------------------------------------------------------
-- The last updated_at trigger not routed through data.touched_at (#308)
-- ---------------------------------------------------------------------------
-- Roadmap 9 moved eleven triggers off the bare `NEW.updated_at =
-- current_timestamp`. This one was left behind because the file it came from
-- matched a `Read(**/*secret*)` deny rule and could not be opened at the time,
-- not because it was any safer: `data.user_secret` carries the same
-- `CHECK (updated_at >= created_at)` and the same exposure. `current_timestamp`
-- is transaction start, so a transaction updating a row created by a
-- transaction that started later writes an updated_at earlier than that row's
-- created_at, and the CHECK rejects the write.
--
-- That matters more here than it did anywhere else, because a CHECK violation
-- on this table prints `DETAIL: Failing row contains (...)`, and this table's
-- rows are generated database passwords.
SET search_path = data, public;

CREATE OR REPLACE FUNCTION fill_user_secret_defaults()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = data.touched_at(NEW.created_at, CASE WHEN TG_OP = 'UPDATE' THEN OLD.updated_at END);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------------
-- Bulk secret distribution (#303)
-- ---------------------------------------------------------------------------
-- Read data.user_secret's own input bounds off its CHECK constraints, so the
-- pre-checks below cannot drift from the schema they protect.
--
-- Unlike data.grade_exception_credit_bounds, which returns NULL when its
-- constraint is reshaped and lets the real write become the only check, this
-- one is required to be exact and its callers refuse to run without it. A NULL
-- bound here would mean the pre-check matched nothing, the constraint fired
-- instead, and PostgreSQL printed the secret body in the error DETAIL -- which
-- is the one outcome these functions exist to prevent. Failing closed on a
-- reshaped constraint is the only safe direction.
CREATE OR REPLACE FUNCTION data.user_secret_input_bounds()
RETURNS TABLE (
    body_octet_limit integer,
    slug_pattern text,
    slug_length_limit integer,
    team_nickname_length_limit integer
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        max((regexp_match(pg_get_constraintdef(secret_constraint.oid),
            'octet_length\(body\) <= (\d+)'))[1]::integer),
        max((regexp_match(pg_get_constraintdef(secret_constraint.oid),
            'slug ~ ''(.+?)''::text'))[1]),
        max((regexp_match(pg_get_constraintdef(secret_constraint.oid),
            'char_length\(slug\) < (\d+)'))[1]::integer),
        max((regexp_match(pg_get_constraintdef(secret_constraint.oid),
            'char_length\(team_nickname\) < (\d+)'))[1]::integer)
    FROM pg_constraint secret_constraint
    WHERE secret_constraint.conrelid = 'data.user_secret'::regclass
        AND secret_constraint.contype = 'c';
$$;

REVOKE ALL ON FUNCTION data.user_secret_input_bounds() FROM PUBLIC;

-- Everything both upsert variants check about a payload, which is everything
-- except who the secret belongs to.
--
-- This is a validator, not a resolver: it returns nothing and raises on the
-- first rule a payload breaks. It exists so that api.upsert_user_secrets and
-- api.upsert_team_secrets cannot drift apart on the rules that keep a body out
-- of an error message -- a divergence would be invisible until the day it leaked.
--
-- Every CHECK and NOT NULL constraint on data.user_secret that a payload could
-- violate is pre-checked here or in the caller, so none of them ever fires.
-- That is not a nicety. PostgreSQL renders a CHECK or NOT NULL violation as:
--
--     ERROR:  new row for relation "user_secret" violates check constraint ...
--     DETAIL: Failing row contains (1, foo, <the secret>, t, 900, null, ...)
--
-- and PostgREST forwards DETAIL to the client. A unique or foreign key
-- violation is safe by contrast -- those name only the key -- so they are left
-- to the write itself, where their messages are more useful than anything
-- restated here.
--
-- p_caller names the api function in every message. The alternative, a shared
-- name, would tell a caller that "upsert_secrets" rejected their row when no
-- such endpoint exists.
CREATE OR REPLACE FUNCTION data.check_user_secret_batch(
    p_secrets jsonb,
    p_target_key text,
    p_caller text
)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    input_count integer;
    bounds record;
    offenders text;
BEGIN
    IF p_secrets IS NULL OR jsonb_typeof(p_secrets) <> 'array' THEN
        RAISE EXCEPTION '% expects a JSON array', p_caller
            USING ERRCODE = '22023';
    END IF;

    -- Measured, never quoted: the payload is the secret material.
    IF octet_length(p_secrets::text) > 4194304 THEN
        RAISE EXCEPTION '% payload exceeds the 4 MB limit', p_caller
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_secrets);

    IF input_count = 0 THEN
        RAISE EXCEPTION '% refuses to import an empty secret list', p_caller
            USING ERRCODE = '22023';
    END IF;

    IF input_count > 2000 THEN
        RAISE EXCEPTION '% accepts at most 2000 secrets, received %', p_caller, input_count
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_secrets) AS element(value)
        WHERE jsonb_typeof(element.value) <> 'object'
    ) THEN
        RAISE EXCEPTION '% expects a JSON object for every secret', p_caller
            USING ERRCODE = '22023';
    END IF;

    -- Positions rather than values, because at this point nothing has been
    -- established about what the values are.
    SELECT string_agg(position::text, ', ' ORDER BY position) INTO offenders
    FROM (
        SELECT element.position
        FROM jsonb_array_elements(p_secrets)
            WITH ORDINALITY AS element(value, position)
        WHERE COALESCE(btrim(element.value->>p_target_key), '') = ''
            OR COALESCE(btrim(element.value->>'slug'), '') = ''
    ) AS incomplete_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION '% requires % and slug on every secret, missing at position: %',
            p_caller, p_target_key, offenders
            USING ERRCODE = '22023';
    END IF;

    -- From here on a row can be named by its target and slug, both of which are
    -- identifiers. The body never appears in a message, in a DETAIL, or in a
    -- returned column.
    --
    -- Duplicate keys are not checked here. Two payload rows collide when they
    -- resolve to the same row of data.user_secret, not when their target
    -- strings match: `netid` is folded to lower case by clean_user_fields() and
    -- `team_nickname` is case sensitive, so there is no one comparison this
    -- function could make that is right for both. Each caller checks it after
    -- resolving its own target, which is also the stricter test.
    SELECT * INTO bounds FROM data.user_secret_input_bounds();

    IF bounds.body_octet_limit IS NULL
        OR bounds.slug_pattern IS NULL
        OR bounds.slug_length_limit IS NULL
        OR bounds.team_nickname_length_limit IS NULL
    THEN
        RAISE EXCEPTION '% cannot read data.user_secret input bounds from its own constraints and will not write without them', p_caller
            USING ERRCODE = 'XX000',
                  DETAIL = 'A reshaped CHECK constraint would let the constraint fire instead of the pre-check, and PostgreSQL prints the failing row -- which here is a secret.',
                  HINT = 'Restore the constraint shape, or teach data.user_secret_input_bounds the new one.';
    END IF;

    -- The slug CHECK is the constraint most likely to fire on a hand-written
    -- payload, and it is one of the ones that would print the body.
    SELECT string_agg(secret_key, ', ' ORDER BY secret_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>p_target_key)
            || '/' || btrim(element.value->>'slug') AS secret_key
        FROM jsonb_array_elements(p_secrets) AS element(value)
        WHERE btrim(element.value->>'slug') !~ bounds.slug_pattern
            OR char_length(btrim(element.value->>'slug')) >= bounds.slug_length_limit
    ) AS malformed_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION '% requires a slug matching % and shorter than % characters: %',
            p_caller, bounds.slug_pattern, bounds.slug_length_limit, offenders
            USING ERRCODE = '22023';
    END IF;

    -- A missing body is not an empty secret. Left to the write it would be a
    -- NOT NULL violation, which prints the rest of the row.
    SELECT string_agg(secret_key, ', ' ORDER BY secret_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>p_target_key)
            || '/' || btrim(element.value->>'slug') AS secret_key
        FROM jsonb_array_elements(p_secrets) AS element(value)
        WHERE jsonb_typeof(element.value->'body') IS DISTINCT FROM 'string'
    ) AS bodyless_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION '% requires a string body on every secret: %', p_caller, offenders
            USING ERRCODE = '22023';
    END IF;

    -- The limit and the offending keys, never the length of any one body: a
    -- rejected secret's size is still something about the secret.
    SELECT string_agg(secret_key, ', ' ORDER BY secret_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>p_target_key)
            || '/' || btrim(element.value->>'slug') AS secret_key
        FROM jsonb_array_elements(p_secrets) AS element(value)
        WHERE octet_length(element.value->>'body') > bounds.body_octet_limit
    ) AS oversized_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION '% requires a body of at most % bytes: %',
            p_caller, bounds.body_octet_limit, offenders
            USING ERRCODE = '22023';
    END IF;

    -- is_user_visible is NOT NULL. A JSON null, or a string "false", casts to
    -- NULL or raises at the write, and the NOT NULL path prints the body.
    SELECT string_agg(secret_key, ', ' ORDER BY secret_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>p_target_key)
            || '/' || btrim(element.value->>'slug') AS secret_key
        FROM jsonb_array_elements(p_secrets) AS element(value)
        WHERE element.value ? 'is_user_visible'
            AND jsonb_typeof(element.value->'is_user_visible') <> 'boolean'
    ) AS unvisible_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION '% requires a boolean is_user_visible when it is given: %', p_caller, offenders
            USING ERRCODE = '22023';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION data.check_user_secret_batch(jsonb, text, text) FROM PUBLIC;

SET search_path = api, public;

-- Distribute per-student secrets in one call, keyed on netid + slug.
--
-- Replaces the per-student `psql` loops in add-final-exam-link.sh,
-- add-students-to-rds.sh, add-students-to-mongodb.sh and
-- add-students-to-meilisearch.sh, each of which spawned one psql per student.
--
-- Why an RPC rather than a POST to a view faculty already hold CRUD on: the
-- uniqueness rule is a *partial* index, `(user_id, slug) WHERE team_nickname IS
-- NULL`. PostgREST's on_conflict carries column names but no index predicate,
-- so it cannot name the arbiter, and re-issuing a student's password raises a
-- duplicate key error instead of replacing it.
--
-- Why this is the *user* variant of a pair rather than one function with a
-- nullable target: the two uniqueness rules are two different partial indexes,
-- and a single function taking both a netid and a team_nickname would pick one
-- index or the other from which field happened to be null. That is a silent
-- change of meaning at the moment a caller makes a mistake -- a payload row
-- whose netid came back null from the caller's own lookup would quietly become
-- a team-wide secret. Here the ON CONFLICT clause names one arbiter with its
-- predicate spelled out and there is no branch at all, so there is no path on
-- which the wrong index could be inferred; and every error message can name a
-- netid without first having to say what kind of target this row turned out to
-- be. See api.upsert_team_secrets for the other half.
--
-- Returns counts only. data.user_secret rows are generated database passwords,
-- so no body appears in the result, in an error message, or in a DETAIL. The
-- checks in data.check_user_secret_batch exist so that every constraint whose
-- violation PostgreSQL would render as `DETAIL: Failing row contains (...)` is
-- caught before the write.
--
-- Re-runnable. A second run of the same payload writes nothing: the DO UPDATE
-- carries a WHERE, so an unchanged secret is not even restamped.
CREATE OR REPLACE FUNCTION upsert_user_secrets(
    p_secrets jsonb,
    p_dry_run boolean DEFAULT false
)
RETURNS TABLE (
    inserted_count integer,
    updated_count integer,
    unchanged_count integer,
    dry_run boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    input_count integer;
    offenders text;
    failed_constraint text;
    failed_sqlstate text;
BEGIN
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;

    PERFORM data.check_user_secret_batch(p_secrets, 'netid', 'upsert_user_secrets');

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_secrets);

    -- The loops this replaces joined netids to users, so an unknown netid
    -- vanished and the run still reported success -- with the secret it was
    -- carrying never delivered to anyone.
    SELECT string_agg(DISTINCT input_secret.netid, ', '
        ORDER BY input_secret.netid) INTO offenders
    FROM (
        SELECT lower(btrim(element.value->>'netid')) AS netid
        FROM jsonb_array_elements(p_secrets) AS element(value)
    ) AS input_secret
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.users student
        WHERE student.netid = input_secret.netid
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'upsert_user_secrets does not know netid: %', offenders
            USING ERRCODE = '23503';
    END IF;

    -- Two payload rows naming one secret. Compared after resolution rather than
    -- on the raw strings, because clean_user_fields() folds netid to lower
    -- case, so `ABC123` and `abc123` are one student and would otherwise reach
    -- the write as two rows -- where ON CONFLICT DO UPDATE raises
    -- "cannot affect row a second time" and a dry run would have said nothing.
    SELECT string_agg(secret_key, ', ' ORDER BY secret_key) INTO offenders
    FROM (
        SELECT student.netid || '/' || btrim(element.value->>'slug') AS secret_key
        FROM jsonb_array_elements(p_secrets) AS element(value)
        JOIN api.users student
            ON student.netid = lower(btrim(element.value->>'netid'))
        GROUP BY 1
        HAVING count(*) > 1
    ) AS duplicate_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'upsert_user_secrets received duplicate netid/slug key: %', offenders
            USING ERRCODE = '23505';
    END IF;

    -- Planned counts. These are what a dry run reports, and on a real run
    -- unchanged_count is taken from here -- the write returns no row for a
    -- secret it decided not to restamp, so there is nothing to count there.
    SELECT
        count(*) FILTER (WHERE prior_secret.id IS NULL)::integer,
        count(*) FILTER (
            WHERE prior_secret.id IS NOT NULL
                AND (prior_secret.body, prior_secret.is_user_visible) IS DISTINCT FROM (
                    element.value->>'body',
                    CASE
                        WHEN element.value ? 'is_user_visible'
                        THEN (element.value->>'is_user_visible')::boolean
                        ELSE prior_secret.is_user_visible
                    END
                )
        )::integer,
        count(*) FILTER (
            WHERE prior_secret.id IS NOT NULL
                AND NOT ((prior_secret.body, prior_secret.is_user_visible) IS DISTINCT FROM (
                    element.value->>'body',
                    CASE
                        WHEN element.value ? 'is_user_visible'
                        THEN (element.value->>'is_user_visible')::boolean
                        ELSE prior_secret.is_user_visible
                    END
                ))
        )::integer
    INTO inserted_count, updated_count, unchanged_count
    FROM jsonb_array_elements(p_secrets) AS element(value)
    JOIN api.users student
        ON student.netid = lower(btrim(element.value->>'netid'))
    LEFT JOIN api.user_secrets prior_secret
        ON prior_secret.user_id = student.id
        AND prior_secret.slug = btrim(element.value->>'slug')
        AND prior_secret.team_nickname IS NULL;

    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'upsert_user_secrets accounted for % of % secrets',
            inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_dry_run THEN
        RETURN NEXT;
        RETURN;
    END IF;

    -- The write is wrapped only so that a constraint nobody pre-checked cannot
    -- reach the client with the row attached. Every constraint on the table
    -- today is pre-checked above, so this handler is unreachable today; it is
    -- here for the constraint somebody adds later. Only the two error classes
    -- that print the failing row are caught -- a unique or foreign key
    -- violation names its key alone, and its own message is better than
    -- anything restated here.
    BEGIN
        WITH resolved_secrets AS (
            SELECT
                student.id AS user_id,
                btrim(element.value->>'slug') AS slug,
                element.value->>'body' AS body,
                CASE
                    WHEN element.value ? 'is_user_visible'
                    THEN (element.value->>'is_user_visible')::boolean
                    -- Absent means "leave it as it is", and on a new row means
                    -- the column default. `true` is pinned by col_default_is in
                    -- tests/db/yeluke-user_secrets.sql.
                    ELSE COALESCE(prior_secret.is_user_visible, true)
                END AS is_user_visible
            FROM jsonb_array_elements(p_secrets) AS element(value)
            JOIN api.users student
                ON student.netid = lower(btrim(element.value->>'netid'))
            LEFT JOIN api.user_secrets prior_secret
                ON prior_secret.user_id = student.id
                AND prior_secret.slug = btrim(element.value->>'slug')
                AND prior_secret.team_nickname IS NULL
        ),
        written_secrets AS (
            INSERT INTO api.user_secrets AS existing_secret (
                user_id, slug, body, is_user_visible
            )
            SELECT
                resolved_secret.user_id,
                resolved_secret.slug,
                resolved_secret.body,
                resolved_secret.is_user_visible
            FROM resolved_secrets resolved_secret
            -- The partial index predicate, which is the whole reason this is an
            -- RPC: PostgREST's on_conflict cannot say `WHERE team_nickname IS
            -- NULL`, so it cannot infer this arbiter.
            ON CONFLICT (user_id, slug) WHERE team_nickname IS NULL
            DO UPDATE SET
                body = EXCLUDED.body,
                is_user_visible = EXCLUDED.is_user_visible
            -- No restamping of a secret that did not change, so re-running a
            -- payload leaves updated_at alone.
            WHERE existing_secret.body IS DISTINCT FROM EXCLUDED.body
                OR existing_secret.is_user_visible IS DISTINCT FROM EXCLUDED.is_user_visible
            -- old is NULL on the insert path and the pre-update row on the
            -- conflict path, so which happened comes out of the write itself
            -- rather than a read taken before it. Two faculty issuing the same
            -- new secret at once would both pass a prior existence check and
            -- both be told they created it.
            RETURNING old.id IS NULL AS was_inserted
        )
        SELECT
            count(*) FILTER (WHERE written_secret.was_inserted)::integer,
            count(*) FILTER (WHERE NOT written_secret.was_inserted)::integer
        INTO inserted_count, updated_count
        FROM written_secrets written_secret;
    EXCEPTION
        WHEN check_violation OR not_null_violation THEN
            GET STACKED DIAGNOSTICS
                failed_constraint = CONSTRAINT_NAME,
                failed_sqlstate = RETURNED_SQLSTATE;
            RAISE EXCEPTION 'upsert_user_secrets refused a write that violates %, and will not report the row because it holds secret material',
                COALESCE(failed_constraint, 'a constraint on data.user_secret')
                USING ERRCODE = failed_sqlstate,
                      HINT = 'This is a gap in the payload pre-checks; the offending row is identified by its netid and slug in the payload you sent.';
    END;

    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'upsert_user_secrets wrote % of % secrets',
            inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION upsert_user_secrets(jsonb, boolean) FROM PUBLIC;

-- Distribute per-team secrets in one call, keyed on team_nickname + slug.
--
-- The other half of the pair. Everything api.upsert_user_secrets says about why
-- this is an RPC, why the target is in the function name rather than in a
-- nullable payload field, and why nothing here returns a body, applies
-- unchanged; the arbiter is the other partial index,
-- `(team_nickname, slug) WHERE user_id IS NULL`.
CREATE OR REPLACE FUNCTION upsert_team_secrets(
    p_secrets jsonb,
    p_dry_run boolean DEFAULT false
)
RETURNS TABLE (
    inserted_count integer,
    updated_count integer,
    unchanged_count integer,
    dry_run boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    input_count integer;
    nickname_limit integer;
    offenders text;
    failed_constraint text;
    failed_sqlstate text;
BEGIN
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;

    PERFORM data.check_user_secret_batch(p_secrets, 'team_nickname', 'upsert_team_secrets');

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_secrets);

    -- data.user_secret's own CHECK on team_nickname length. An unknown team is
    -- refused below and a too-long nickname could not name a real team either,
    -- but constraint evaluation order is not guaranteed, so the CHECK that
    -- would print the body is taken out of play explicitly rather than left to
    -- lose a race with the foreign key that would not.
    SELECT bounds.team_nickname_length_limit INTO nickname_limit
    FROM data.user_secret_input_bounds() AS bounds;

    SELECT string_agg(DISTINCT input_secret.team_nickname, ', '
        ORDER BY input_secret.team_nickname) INTO offenders
    FROM (
        SELECT btrim(element.value->>'team_nickname') AS team_nickname
        FROM jsonb_array_elements(p_secrets) AS element(value)
    ) AS input_secret
    WHERE char_length(input_secret.team_nickname) >= nickname_limit;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'upsert_team_secrets requires a team nickname shorter than % characters: %',
            nickname_limit, offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(DISTINCT input_secret.team_nickname, ', '
        ORDER BY input_secret.team_nickname) INTO offenders
    FROM (
        SELECT btrim(element.value->>'team_nickname') AS team_nickname
        FROM jsonb_array_elements(p_secrets) AS element(value)
    ) AS input_secret
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.teams course_team
        WHERE course_team.nickname = input_secret.team_nickname
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'upsert_team_secrets does not know team nickname: %', offenders
            USING ERRCODE = '23503';
    END IF;

    -- Two payload rows naming one secret. data.team.nickname is case sensitive,
    -- so this is the raw comparison for teams -- but it is written after
    -- resolution for the same reason as its user twin: the rule being enforced
    -- is the unique index, not string equality.
    SELECT string_agg(secret_key, ', ' ORDER BY secret_key) INTO offenders
    FROM (
        SELECT course_team.nickname || '/' || btrim(element.value->>'slug') AS secret_key
        FROM jsonb_array_elements(p_secrets) AS element(value)
        JOIN api.teams course_team
            ON course_team.nickname = btrim(element.value->>'team_nickname')
        GROUP BY 1
        HAVING count(*) > 1
    ) AS duplicate_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'upsert_team_secrets received duplicate team_nickname/slug key: %', offenders
            USING ERRCODE = '23505';
    END IF;

    SELECT
        count(*) FILTER (WHERE prior_secret.id IS NULL)::integer,
        count(*) FILTER (
            WHERE prior_secret.id IS NOT NULL
                AND (prior_secret.body, prior_secret.is_user_visible) IS DISTINCT FROM (
                    element.value->>'body',
                    CASE
                        WHEN element.value ? 'is_user_visible'
                        THEN (element.value->>'is_user_visible')::boolean
                        ELSE prior_secret.is_user_visible
                    END
                )
        )::integer,
        count(*) FILTER (
            WHERE prior_secret.id IS NOT NULL
                AND NOT ((prior_secret.body, prior_secret.is_user_visible) IS DISTINCT FROM (
                    element.value->>'body',
                    CASE
                        WHEN element.value ? 'is_user_visible'
                        THEN (element.value->>'is_user_visible')::boolean
                        ELSE prior_secret.is_user_visible
                    END
                ))
        )::integer
    INTO inserted_count, updated_count, unchanged_count
    FROM jsonb_array_elements(p_secrets) AS element(value)
    JOIN api.teams course_team
        ON course_team.nickname = btrim(element.value->>'team_nickname')
    LEFT JOIN api.user_secrets prior_secret
        ON prior_secret.team_nickname = course_team.nickname
        AND prior_secret.slug = btrim(element.value->>'slug')
        AND prior_secret.user_id IS NULL;

    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'upsert_team_secrets accounted for % of % secrets',
            inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_dry_run THEN
        RETURN NEXT;
        RETURN;
    END IF;

    BEGIN
        WITH resolved_secrets AS (
            SELECT
                course_team.nickname AS team_nickname,
                btrim(element.value->>'slug') AS slug,
                element.value->>'body' AS body,
                CASE
                    WHEN element.value ? 'is_user_visible'
                    THEN (element.value->>'is_user_visible')::boolean
                    ELSE COALESCE(prior_secret.is_user_visible, true)
                END AS is_user_visible
            FROM jsonb_array_elements(p_secrets) AS element(value)
            JOIN api.teams course_team
                ON course_team.nickname = btrim(element.value->>'team_nickname')
            LEFT JOIN api.user_secrets prior_secret
                ON prior_secret.team_nickname = course_team.nickname
                AND prior_secret.slug = btrim(element.value->>'slug')
                AND prior_secret.user_id IS NULL
        ),
        written_secrets AS (
            INSERT INTO api.user_secrets AS existing_secret (
                team_nickname, slug, body, is_user_visible
            )
            SELECT
                resolved_secret.team_nickname,
                resolved_secret.slug,
                resolved_secret.body,
                resolved_secret.is_user_visible
            FROM resolved_secrets resolved_secret
            ON CONFLICT (team_nickname, slug) WHERE user_id IS NULL
            DO UPDATE SET
                body = EXCLUDED.body,
                is_user_visible = EXCLUDED.is_user_visible
            WHERE existing_secret.body IS DISTINCT FROM EXCLUDED.body
                OR existing_secret.is_user_visible IS DISTINCT FROM EXCLUDED.is_user_visible
            RETURNING old.id IS NULL AS was_inserted
        )
        SELECT
            count(*) FILTER (WHERE written_secret.was_inserted)::integer,
            count(*) FILTER (WHERE NOT written_secret.was_inserted)::integer
        INTO inserted_count, updated_count
        FROM written_secrets written_secret;
    EXCEPTION
        WHEN check_violation OR not_null_violation THEN
            GET STACKED DIAGNOSTICS
                failed_constraint = CONSTRAINT_NAME,
                failed_sqlstate = RETURNED_SQLSTATE;
            RAISE EXCEPTION 'upsert_team_secrets refused a write that violates %, and will not report the row because it holds secret material',
                COALESCE(failed_constraint, 'a constraint on data.user_secret')
                USING ERRCODE = failed_sqlstate,
                      HINT = 'This is a gap in the payload pre-checks; the offending row is identified by its team_nickname and slug in the payload you sent.';
    END;

    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'upsert_team_secrets wrote % of % secrets',
            inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION upsert_team_secrets(jsonb, boolean) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
-- Writing a secret is already faculty-only: data.user_secret's RLS WITH CHECK
-- admits `request.user_role() = 'faculty'` alone, and these functions are
-- SECURITY INVOKER writing through api.user_secrets, so that still governs.
-- These grants say who may reach the endpoint at all.
GRANT EXECUTE ON FUNCTION data.user_secret_input_bounds() TO faculty;
GRANT EXECUTE ON FUNCTION data.check_user_secret_batch(jsonb, text, text) TO faculty;
GRANT EXECUTE ON FUNCTION api.upsert_user_secrets(jsonb, boolean) TO faculty;
GRANT EXECUTE ON FUNCTION api.upsert_team_secrets(jsonb, boolean) TO faculty;

-- ---------------------------------------------------------------------------
-- Compatibility version
-- ---------------------------------------------------------------------------
-- admin_api_version reaches 9: two RPCs added, nothing removed, so the floor
-- check clients use stays correct. The api schema shape is unchanged -- no
-- view, no column, no removal -- so schema_compatibility_version stays 4.
create or replace view platform_version as
    select
        'yelukerest'::text as platform,
        1::integer as platform_compatibility_version,
        4::integer as schema_compatibility_version,
        9::integer as admin_api_version;

alter view platform_version owner to api;

COMMENT ON VIEW platform_version IS
    'Single-row compatibility metadata for course admin preflight checks';
COMMENT ON COLUMN platform_version.platform IS
    'Platform identifier expected by course admin tooling';
COMMENT ON COLUMN platform_version.platform_compatibility_version IS
    'Integer compatibility version for Yelukerest platform behavior';
COMMENT ON COLUMN platform_version.schema_compatibility_version IS
    'Integer identifying the api schema shape. Check for membership in the set of shapes the client supports, NOT with >=: a shape can lose columns and views, and version 4 did. A client pinned to >= 3 would pass its own preflight against 4 and then fail on its first request.';
COMMENT ON COLUMN platform_version.admin_api_version IS
    'Integer compatibility version for generic admin API operations. Only ever grows -- each bump adds an RPC without removing one -- so >= is the correct check.';
