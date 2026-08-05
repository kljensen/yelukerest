CREATE OR REPLACE VIEW assignment_field_submission_events AS
    SELECT * FROM data.assignment_field_submission_event;

ALTER VIEW assignment_field_submission_events OWNER TO api;
