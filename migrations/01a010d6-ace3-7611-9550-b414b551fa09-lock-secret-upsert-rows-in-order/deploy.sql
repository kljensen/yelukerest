-- Take the secret-upsert row locks in one order, closing a deadlock the
-- split write introduced.
--
-- Splitting on whether the caller supplied `is_user_visible` (the fix for the
-- visibility exposure) put the two halves of a batch in separate statements.
-- Two overlapping batches that partition the same keys differently then reach
-- row A through one half and row B through the other, in opposite orders, and
-- each ends up holding what the other waits for. Both payloads can list their
-- keys in the same order and still deadlock, because it is the partitioning
-- that reorders them -- which is also why an ORDER BY inside either statement
-- cannot help: the cycle is across the two, not within either.
--
-- This is a NEW migration rather than an edit to upsert-user-secrets, because
-- that one has been applied and Zapadka refuses a changed definition:
--
--     applied migration 01a0108c upsert-user-secrets has changed since it was
--     deployed [history.definition_changed]
--     deploy.sql has been edited since it ran; restore it and write a new
--     migration with the correction, so the history keeps both facts
--
-- Both facts are worth keeping: the split fixed a security bug, and the split
-- cost a deadlock that had to be closed separately.
--
-- Known residual, deliberately not addressed here: keys that do not exist yet
-- cannot be locked, so two callers first-issuing the same brand-new secrets
-- with opposite partitioning can still deadlock on the unique index. Measured,
-- not assumed -- and measured to be caused by having two statements rather
-- than by upserts in general. It fails loudly, exposes nothing, and is
-- retryable. Closing it means a third ordered statement and a rebuild of the
-- insert/update accounting, which is its own change.

SET search_path = api, public;

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
    -- unchanged_count is *predicted* here and recomputed after the write, never
    -- carried across it. The write returns no row for a secret it declined to
    -- restamp, so a retained prediction would be a claim about a moment that has
    -- already passed by the time it is reported -- see the derivation below.
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
    -- Take every conflict-row lock up front, in one statement, in one order.
    --
    -- Splitting the write into two statements introduced a lock-order
    -- inversion. Two overlapping batches that supply is_user_visible for
    -- different keys partition those keys differently, so one call reaches row
    -- A through its supplied half and row B through its omitted half while the
    -- other does the reverse -- and each ends up holding what the other is
    -- waiting for. Both payloads can list their keys in the same order and
    -- still deadlock, because it is the partitioning that reorders them, which
    -- is also why an ORDER BY inside either statement cannot help: the cycle is
    -- across the two, not within either.
    --
    -- One ordering for every caller means the cycle cannot form however a
    -- payload happens to partition. `LockRows` sits above `Sort` in the plan,
    -- so the rows really are locked in the ordered sequence rather than merely
    -- returned in it.
    --
    -- Read through api.user_secrets rather than data.user_secret: faculty hold
    -- nothing at all on the base table -- pinned by table_privs_are in
    -- tests/db/yeluke-user_secrets.sql -- so locking it directly raises
    -- "permission denied for table user_secret". The view is auto-updatable and
    -- propagates the lock to the base row.
    --
    -- api.upsert_team_secrets orders by (team_nickname, slug) instead. The two
    -- can never contend: a user secret has team_nickname NULL and a team secret
    -- has user_id NULL, so their row sets are disjoint and there is no
    -- cross-function cycle to order against.
    --
    -- Rows that do not exist yet cannot be locked here, and those keys still
    -- race on the unique index. See the report accompanying this change: that
    -- residual is real and is not closed by this statement.
    PERFORM 1
    FROM api.user_secrets locked_secret
    WHERE locked_secret.team_nickname IS NULL
        AND (locked_secret.user_id, locked_secret.slug) IN (
            SELECT student.id, btrim(element.value->>'slug')
            FROM jsonb_array_elements(p_secrets) AS element(value)
            JOIN api.users student
                ON student.netid = lower(btrim(element.value->>'netid'))
        )
    ORDER BY locked_secret.user_id, locked_secret.slug
    FOR UPDATE;

    -- Two writes over disjoint halves of the payload, split on whether the
    -- caller said anything about visibility.
    --
    -- The single write this replaces resolved `is_user_visible` from a read of
    -- the existing row taken before it, and then applied the result
    -- unconditionally in DO UPDATE. That turned "absent means leave it alone"
    -- into "absent means whatever it was a moment ago", and the difference is a
    -- race that fails in the exposing direction: one caller issues a secret
    -- hidden, a second caller whose payload omits the field read no row and so
    -- proposes `true`, the hidden insert lands first, and the second's
    -- ON CONFLICT flips a deliberately hidden password student-visible.
    --
    -- The fix is not a narrower window. The omitted half never mentions the
    -- column at all -- not in the INSERT list, not in the DO UPDATE -- so there
    -- is no read to go stale and nothing to lose a race with. A genuinely new
    -- row takes the column default straight from the schema, which is also one
    -- fewer copy of `true` to keep in step with data.user_secret.
    --
    -- Carrying a "was it supplied" flag through EXCLUDED is not available:
    -- EXCLUDED exposes only the columns being inserted, and is_user_visible is
    -- NOT NULL, so there is no sentinel to smuggle the distinction in.
    --
    -- The halves are disjoint by construction -- a payload row supplies the
    -- field or does not -- and duplicate netid/slug keys were refused above, so
    -- no row is a conflict target twice and the two statements cannot collide.
    BEGIN
        WITH resolved_secrets AS (
            SELECT
                student.id AS user_id,
                btrim(element.value->>'slug') AS slug,
                element.value->>'body' AS body,
                element.value ? 'is_user_visible' AS has_visibility,
                (element.value->>'is_user_visible')::boolean AS is_user_visible
            FROM jsonb_array_elements(p_secrets) AS element(value)
            JOIN api.users student
                ON student.netid = lower(btrim(element.value->>'netid'))
        ),
        -- Visibility supplied: it is written on both paths, and a change to it
        -- alone is enough to count as an update.
        written_with_visibility AS (
            INSERT INTO api.user_secrets AS existing_secret (
                user_id, slug, body, is_user_visible
            )
            SELECT
                resolved_secret.user_id,
                resolved_secret.slug,
                resolved_secret.body,
                resolved_secret.is_user_visible
            FROM resolved_secrets resolved_secret
            WHERE resolved_secret.has_visibility
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
        ),
        -- Visibility omitted: the column appears nowhere, so an existing row
        -- keeps whatever it holds and a new one takes the schema default.
        written_without_visibility AS (
            INSERT INTO api.user_secrets AS existing_secret (
                user_id, slug, body
            )
            SELECT
                resolved_secret.user_id,
                resolved_secret.slug,
                resolved_secret.body
            FROM resolved_secrets resolved_secret
            WHERE NOT resolved_secret.has_visibility
            ON CONFLICT (user_id, slug) WHERE team_nickname IS NULL
            DO UPDATE SET
                body = EXCLUDED.body
            WHERE existing_secret.body IS DISTINCT FROM EXCLUDED.body
            RETURNING old.id IS NULL AS was_inserted
        ),
        written_secrets AS (
            SELECT was_inserted FROM written_with_visibility
            UNION ALL
            SELECT was_inserted FROM written_without_visibility
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

    -- Every payload row has to end up somewhere, and a row the write did not
    -- return is a row it left alone. Deriving unchanged_count here rather than
    -- keeping the prediction made before the write is what makes two callers
    -- issuing the same new secret at once both succeed: both plan it as an
    -- insert, the first commits, and the second's DO UPDATE takes its WHERE
    -- false branch and returns nothing. Its real answer is "unchanged", which
    -- only the write knows; a retained prediction of zero would have made the
    -- sum come to nothing and aborted an idempotent request.
    --
    -- The invariant that survives is an upper bound, and it is the one worth
    -- keeping: the write must not have touched more rows than the payload
    -- named. That is what a mis-inferred arbiter or a resolution join fanning
    -- out would break, and neither is caught by an equality that derives one of
    -- its own terms.
    IF inserted_count + updated_count > input_count THEN
        RAISE EXCEPTION 'upsert_user_secrets wrote % rows for % secrets',
            inserted_count + updated_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    unchanged_count := input_count - inserted_count - updated_count;

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

    -- The ordered pre-lock, on the other key. See api.upsert_user_secrets for
    -- why it is here and why it reads the view rather than the base table.
    PERFORM 1
    FROM api.user_secrets locked_secret
    WHERE locked_secret.user_id IS NULL
        AND (locked_secret.team_nickname, locked_secret.slug) IN (
            SELECT course_team.nickname, btrim(element.value->>'slug')
            FROM jsonb_array_elements(p_secrets) AS element(value)
            JOIN api.teams course_team
                ON course_team.nickname = btrim(element.value->>'team_nickname')
        )
    ORDER BY locked_secret.team_nickname, locked_secret.slug
    FOR UPDATE;

    -- Split on whether the caller said anything about visibility, for the
    -- reasons set out at length in api.upsert_user_secrets. A team secret is
    -- readable by every current member of the team, so the race this closes
    -- exposed a password to more people here than it did there.
    BEGIN
        WITH resolved_secrets AS (
            SELECT
                course_team.nickname AS team_nickname,
                btrim(element.value->>'slug') AS slug,
                element.value->>'body' AS body,
                element.value ? 'is_user_visible' AS has_visibility,
                (element.value->>'is_user_visible')::boolean AS is_user_visible
            FROM jsonb_array_elements(p_secrets) AS element(value)
            JOIN api.teams course_team
                ON course_team.nickname = btrim(element.value->>'team_nickname')
        ),
        written_with_visibility AS (
            INSERT INTO api.user_secrets AS existing_secret (
                team_nickname, slug, body, is_user_visible
            )
            SELECT
                resolved_secret.team_nickname,
                resolved_secret.slug,
                resolved_secret.body,
                resolved_secret.is_user_visible
            FROM resolved_secrets resolved_secret
            WHERE resolved_secret.has_visibility
            ON CONFLICT (team_nickname, slug) WHERE user_id IS NULL
            DO UPDATE SET
                body = EXCLUDED.body,
                is_user_visible = EXCLUDED.is_user_visible
            WHERE existing_secret.body IS DISTINCT FROM EXCLUDED.body
                OR existing_secret.is_user_visible IS DISTINCT FROM EXCLUDED.is_user_visible
            RETURNING old.id IS NULL AS was_inserted
        ),
        written_without_visibility AS (
            INSERT INTO api.user_secrets AS existing_secret (
                team_nickname, slug, body
            )
            SELECT
                resolved_secret.team_nickname,
                resolved_secret.slug,
                resolved_secret.body
            FROM resolved_secrets resolved_secret
            WHERE NOT resolved_secret.has_visibility
            ON CONFLICT (team_nickname, slug) WHERE user_id IS NULL
            DO UPDATE SET
                body = EXCLUDED.body
            WHERE existing_secret.body IS DISTINCT FROM EXCLUDED.body
            RETURNING old.id IS NULL AS was_inserted
        ),
        written_secrets AS (
            SELECT was_inserted FROM written_with_visibility
            UNION ALL
            SELECT was_inserted FROM written_without_visibility
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

    -- Derived after the write, and an upper bound rather than an equality, for
    -- the reasons set out in api.upsert_user_secrets.
    IF inserted_count + updated_count > input_count THEN
        RAISE EXCEPTION 'upsert_team_secrets wrote % rows for % secrets',
            inserted_count + updated_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    unchanged_count := input_count - inserted_count - updated_count;

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

-- The signatures are unchanged, so the existing grants still apply; this
-- only replaces the bodies. Tell PostgREST anyway -- a replaced body is
-- not a cache concern, but a redeploy that skipped this would be.
NOTIFY pgrst, 'reload schema';
