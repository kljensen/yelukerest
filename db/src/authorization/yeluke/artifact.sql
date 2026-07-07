-- Let the `api` role---the view owner---query the data.
GRANT SELECT, INSERT, UPDATE, DELETE ON data.artifact TO api;

-- Define who can access artifact metadata.
ALTER TABLE data.artifact ENABLE ROW LEVEL SECURITY;

CREATE POLICY artifact_access_policy ON data.artifact TO api
USING (
    (
        request.user_role() = ANY('{student,ta}'::text[])
        AND is_user_visible
        AND request.user_id() = user_id
    )
    OR
    request.user_role() = 'faculty'
) WITH CHECK (
    request.user_role() = 'faculty'
);

-- Students can read their visible artifacts; faculty can manage all artifacts.
GRANT SELECT ON api.artifacts TO student, ta;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.artifacts TO faculty;
