-- Revert enforce-scopes-on-writes: restore the hook without the scope gate.
-- Reverting reopens the hole described in deploy.sql -- a read-only token
-- regains the ability to write -- so this exists for completeness, not as a
-- routine operation.
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
END;
$$;


ALTER FUNCTION api.check_request_jwt() OWNER TO yelukerest_migrator;
REVOKE ALL ON FUNCTION api.check_request_jwt() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.check_request_jwt() TO anonymous, student, ta, faculty, observer, app;

NOTIFY pgrst, 'reload schema';
