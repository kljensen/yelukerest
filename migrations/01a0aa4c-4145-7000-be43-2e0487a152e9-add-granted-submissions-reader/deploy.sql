-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.
-- Data grants for consuming apps, step 3 of 3: the reader (issue #386,
-- ADR 0005).
--
-- Replaces the stub 01a0aa42-add-grant-consumer-role shipped. The reader is
-- the only thing a grant credential can call, so it has to return exactly
-- the granted values and nothing else, and its paging has to be correct for
-- how submissions actually change.
--
-- The rules each row follows, each pinned in tests/db/yeluke-api-grants.sql:
--
--   * A submission appears only when every granted field has a child row
--     with a non-empty body. One that has not filled in a granted field is
--     left out, not shown with blanks. Whitespace counts as content.
--   * For an individual assignment the identity comes from the submission's
--     own user; for a team assignment from its team_nickname, with the
--     person-level keys null. Never the editor, never one team member.
--     Granted-but-null values stay in the output as null; ungranted keys are
--     absent. jsonb_build_object from granted values only: there is no column
--     for ?select=, ordering, filtering or embedding to reach.
--   * Rows come in submission id order and p_after_id pages through them.
--     The default limit is 200; a null or non-positive limit is refused,
--     because a caller that passes one has a bug and silently substituting a
--     default would hide it; a positive limit is capped at 500.
--   * A slug the grant does not cover returns an empty array, after the
--     credential and the grant row have been checked, so the reply says
--     nothing about assignments the caller cannot see.
--
-- Why id order and not a timestamp: editing a field updates the child row's
-- timestamp but not the parent submission's
-- (data.fill_assignment_field_submission_defaults), and clearing a field
-- deletes the child row and leaves no marker. A timestamp cursor would miss
-- both. This is a current-state listing; the COMMENT below is the contract a
-- consumer follows.
CREATE OR REPLACE FUNCTION api.granted_submissions(p_assignment_slug text = NULL, p_after_id int = NULL, p_limit int = 200) RETURNS SETOF jsonb STABLE SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    max_limit CONSTANT int := 500;
    grant_id_text text;
    live_grant data.api_grant%ROWTYPE;
    page_limit int;
BEGIN
    IF request.user_role() IS DISTINCT FROM 'grant_consumer' THEN
        RAISE insufficient_privilege USING MESSAGE = 'granted_submissions accepts only a grant credential';
    END IF;
    grant_id_text := request.jwt_claim('grant_id');
    IF grant_id_text IS NULL
       OR grant_id_text !~ '^[1-9][0-9]{0,8}$'
       OR request.jwt_claim('sub') IS DISTINCT FROM 'grant:' || grant_id_text THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid grant credential';
    END IF;

    -- Read on every call, so revocation applies to the next request.
    SELECT g.* INTO live_grant FROM data.api_grant g WHERE g.id = grant_id_text::int;
    IF NOT FOUND OR live_grant.revoked_at IS NOT NULL OR live_grant.expires_at <= current_timestamp THEN
        RAISE insufficient_privilege USING MESSAGE = 'this grant has been revoked or has expired';
    END IF;

    IF p_limit IS NULL OR p_limit <= 0 THEN
        RAISE EXCEPTION 'p_limit must be a positive integer (at most %)', max_limit USING ERRCODE = '22023';
    END IF;
    page_limit := least(p_limit, max_limit);

    RETURN QUERY
    SELECT jsonb_build_object(
        'assignment_slug', s.assignment_slug,
        'submission_id', s.id,
        'is_team', s.is_team,
        'created_at', s.created_at,
        'updated_at', s.updated_at,
        'identity', (
            SELECT coalesce(jsonb_object_agg(k, CASE k
                WHEN 'netid' THEN to_jsonb(u.netid)
                WHEN 'name' THEN to_jsonb(u.name)
                WHEN 'nickname' THEN to_jsonb(u.nickname)
                WHEN 'team_nickname' THEN to_jsonb(s.team_nickname)
            END), '{}'::jsonb)
            FROM unnest(ga.identity) k
        ),
        'fields', granted.fields
    )
    FROM data.assignment_submission s
    JOIN data.api_grant_assignment ga
      ON ga.grant_id = live_grant.id AND ga.assignment_slug = s.assignment_slug
    LEFT JOIN data."user" u
      ON NOT s.is_team AND u.id = s.user_id
    CROSS JOIN LATERAL (
        SELECT jsonb_object_agg(f.field_slug, jsonb_build_object('body', fs.body, 'updated_at', fs.updated_at)) AS fields,
               bool_and(coalesce(fs.body, '') <> '') AS complete
        FROM data.api_grant_assignment_field f
        LEFT JOIN data.assignment_field_submission fs
          ON fs.assignment_submission_id = s.id
         AND fs.assignment_slug = f.assignment_slug
         AND fs.assignment_field_slug = f.field_slug
        WHERE f.grant_id = ga.grant_id AND f.assignment_slug = ga.assignment_slug
    ) granted
    WHERE (p_assignment_slug IS NULL OR s.assignment_slug = p_assignment_slug)
      AND (p_after_id IS NULL OR s.id > p_after_id)
      AND granted.complete
    ORDER BY s.id
    LIMIT page_limit;
END;
$$
; COMMENT ON FUNCTION api.granted_submissions(text, int, int) IS 'Submissions a grant credential may read, as {assignment_slug, submission_id, is_team, created_at, updated_at, identity, fields}, in submission id order. Pass the last submission_id as p_after_id for the next page; p_limit defaults to 200 and is capped at 500. Paging contract: this is a current-state listing, not a change feed, and the pages of one pass are not one snapshot. Walk every page from the start each cycle and replace the local set only after a complete pass; a submission that stops meeting the grant (a cleared field) simply stops appearing.'
; NOTIFY pgrst, 'reload schema'
