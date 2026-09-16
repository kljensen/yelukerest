-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- Puts the stub from 01a0aa42-add-grant-consumer-role back: every grant
-- credential is refused again until this migration is redeployed. Ownership,
-- privileges and the role stay as they were; CREATE OR REPLACE keeps them.
CREATE OR REPLACE FUNCTION api.granted_submissions(p_assignment_slug text = NULL, p_after_id int = NULL, p_limit int = 200) RETURNS SETOF jsonb STABLE SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    grant_id_text text;
    live_grant data.api_grant%ROWTYPE;
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

    SELECT g.* INTO live_grant FROM data.api_grant g WHERE g.id = grant_id_text::int;
    IF NOT FOUND OR live_grant.revoked_at IS NOT NULL OR live_grant.expires_at <= current_timestamp THEN
        RAISE insufficient_privilege USING MESSAGE = 'this grant has been revoked or has expired';
    END IF;

    RAISE EXCEPTION 'granted_submissions is not yet available' USING ERRCODE = '0A000';
END;
$$
; COMMENT ON FUNCTION api.granted_submissions(text, int, int) IS 'Reader for grant credentials. Not yet available: refuses every call until the add-granted-submissions-reader migration.'
; NOTIFY pgrst, 'reload schema'
