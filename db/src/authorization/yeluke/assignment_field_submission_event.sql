-- The history table is written only by the
-- record_assignment_field_submission_event trigger (SECURITY DEFINER),
-- so the api role needs SELECT only.
GRANT SELECT ON data.assignment_field_submission_event TO api;

ALTER TABLE data.assignment_field_submission_event ENABLE ROW LEVEL SECURITY;

CREATE POLICY assignment_field_submission_event_access_policy
    ON data.assignment_field_submission_event TO api
USING (
    request.user_role() = 'faculty'
);

GRANT SELECT ON api.assignment_field_submission_events TO faculty;
