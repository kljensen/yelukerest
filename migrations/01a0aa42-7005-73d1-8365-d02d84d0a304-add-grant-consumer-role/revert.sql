-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- Reverting invalidates every grant credential in circulation: the role it
-- names can no longer reach anything. The grant rows themselves stay, with
-- the previous migration. The two roles stay too, for the reason authapp's
-- does: roles are cluster-wide, and dropping one here would pull it out from
-- under every other database in the cluster. With the grants below revoked
-- they can do nothing.
DROP FUNCTION IF EXISTS api.granted_submissions(text, int, int)
; DROP FUNCTION IF EXISTS api.create_api_grant(text, jsonb, timestamp with time zone)
; DROP FUNCTION IF EXISTS auth.sign_grant_jwt(int, timestamp with time zone, text)
; DROP POLICY IF EXISTS api_grant_reader_policy ON data.assignment_submission
; DROP POLICY IF EXISTS api_grant_reader_policy ON data.assignment_field_submission
; DROP POLICY IF EXISTS api_grant_reader_policy ON data."user"
; REVOKE ALL ON data.api_grant, data.api_grant_assignment, data.api_grant_assignment_field, data.assignment_submission, data.assignment_field_submission, data."user" FROM grant_reader
; REVOKE ALL ON SCHEMA api, data FROM grant_reader
; REVOKE ALL ON SCHEMA api FROM grant_consumer
;
-- The hook exactly as 01a0481a-bound-student-row-writes left it, audience
-- test included: a revert restores the previous behaviour, even the part that
-- was wrong.
CREATE OR REPLACE FUNCTION api.check_request_jwt() RETURNS void STABLE SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, api, settings, request, pg_temp AS $$
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
$$
; ALTER FUNCTION api.check_request_jwt() OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.check_request_jwt() FROM public
;
-- CREATE OR REPLACE keeps the function's ACL, so the consumer's EXECUTE has
-- to be taken back by name, or the role would stay on the hook after the
-- reader it exists for is gone.
REVOKE ALL ON FUNCTION api.check_request_jwt() FROM grant_consumer
; GRANT execute ON FUNCTION api.check_request_jwt() TO anonymous, student, ta, faculty, observer, app
; DO $$
BEGIN
    IF has_function_privilege('grant_consumer', 'api.check_request_jwt()', 'EXECUTE') THEN
        RAISE EXCEPTION 'grant_consumer still holds EXECUTE on api.check_request_jwt()';
    END IF;
END;
$$
; NOTIFY pgrst, 'reload schema'
