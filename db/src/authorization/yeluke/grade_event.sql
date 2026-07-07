GRANT SELECT ON data.assignment_grade_event TO api;
GRANT SELECT ON data.quiz_grade_event TO api;
GRANT SELECT ON data.grade_event TO api;

ALTER TABLE data.assignment_grade_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.quiz_grade_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE data.grade_event ENABLE ROW LEVEL SECURITY;

CREATE POLICY assignment_grade_event_access_policy ON data.assignment_grade_event TO api
USING (
    request.user_role() = 'faculty'
);

CREATE POLICY quiz_grade_event_access_policy ON data.quiz_grade_event TO api
USING (
    request.user_role() = 'faculty'
);

CREATE POLICY grade_event_access_policy ON data.grade_event TO api
USING (
    request.user_role() = 'faculty'
);

GRANT SELECT ON api.assignment_grade_events TO faculty;
GRANT SELECT ON api.quiz_grade_events TO faculty;
GRANT SELECT ON api.grade_events TO faculty;
