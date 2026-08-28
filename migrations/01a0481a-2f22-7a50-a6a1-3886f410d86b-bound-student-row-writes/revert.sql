-- Revert bound-student-row-writes: drop the statement-level row bound and
-- restore api.check_request_jwt without the budget reset.
--
-- Reverting removes a blast-radius control: one student statement regains the
-- ability to change every row row-level security admits, which for a team
-- submission is other people's work. This exists so the migration is
-- reversible, not as a routine operation.

DROP TRIGGER IF EXISTS tg_engagement_row_bound_delete ON data.engagement;
DROP TRIGGER IF EXISTS tg_engagement_row_bound_update ON data.engagement;
DROP TRIGGER IF EXISTS tg_engagement_row_bound_insert ON data.engagement;

DROP TRIGGER IF EXISTS tg_assignment_submission_row_bound_delete ON data.assignment_submission;
DROP TRIGGER IF EXISTS tg_assignment_submission_row_bound_update ON data.assignment_submission;
DROP TRIGGER IF EXISTS tg_assignment_submission_row_bound_insert ON data.assignment_submission;

DROP TRIGGER IF EXISTS tg_assignment_field_submission_single_parent_delete ON data.assignment_field_submission;
DROP TRIGGER IF EXISTS tg_assignment_field_submission_single_parent_update ON data.assignment_field_submission;
DROP TRIGGER IF EXISTS tg_assignment_field_submission_single_parent_insert ON data.assignment_field_submission;

DROP TRIGGER IF EXISTS tg_assignment_field_submission_row_bound_delete ON data.assignment_field_submission;
DROP TRIGGER IF EXISTS tg_assignment_field_submission_row_bound_update ON data.assignment_field_submission;
DROP TRIGGER IF EXISTS tg_assignment_field_submission_row_bound_insert ON data.assignment_field_submission;

DROP FUNCTION IF EXISTS data.enforce_single_assignment_submission();
DROP FUNCTION IF EXISTS data.enforce_request_row_bound();
DROP FUNCTION IF EXISTS data.request_row_bound_default();

-- api.check_request_jwt as 01a02545-enforce-scopes-on-writes left it, without
-- the row-budget reset. Restored before the function it called is dropped.
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

    scopes_claim := request.jwt_claim('scopes');
    IF coalesce(scopes_claim, '') <> '' THEN
        request_method := upper(coalesce(current_setting('request.method', true), ''));
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

DROP FUNCTION IF EXISTS request.reset_row_bound_counters();

NOTIFY pgrst, 'reload schema';
