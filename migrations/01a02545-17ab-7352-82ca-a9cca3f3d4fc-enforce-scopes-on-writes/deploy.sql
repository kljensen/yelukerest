-- Enforce the `scopes` claim on writes (issue #317).
--
-- Personal access tokens default to read-only, and the MCP consent page leaves
-- the write scope unchecked, but nothing on the PostgREST path actually read
-- the claim. Row-level security answers "who are you", never "what was this
-- token allowed to do", so a read-only token could write anything its owner
-- could. That made the read-only default decorative -- which matters most for
-- exactly the case it was built for: a student's AI assistant holding a token
-- it was told is read-only.

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
