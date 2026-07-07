-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.assignment_field_submission to api;

-- Define the who can access assignment_field_submission data.
-- Enable RLS on the table holding the data.
alter table data.assignment_field_submission enable row level security;

DROP POLICY IF EXISTS assignment_field_submission_access_policy
    ON data.assignment_field_submission;

CREATE POLICY assignment_field_submission_select_policy
    ON data.assignment_field_submission
    FOR SELECT
    TO api
    USING (
        (
            request.user_role() = ANY('{student,ta}'::text[])
            AND (
                submitter_user_id = request.user_id()
                OR EXISTS (
                    SELECT ass_sub.id
                    FROM api.assignment_submissions AS ass_sub
                    WHERE ass_sub.id = assignment_submission_id
                )
                OR data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id)
            )
        )
        OR request.user_role() = 'faculty'
    );

CREATE POLICY assignment_field_submission_insert_policy
    ON data.assignment_field_submission
    FOR INSERT
    TO api
    WITH CHECK (
        request.user_role() = 'faculty'
        OR (
            request.user_role() = ANY('{student,ta}'::text[])
            AND submitter_user_id = request.user_id()
            AND data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id)
        )
    );

CREATE POLICY assignment_field_submission_update_policy
    ON data.assignment_field_submission
    FOR UPDATE
    TO api
    USING (
        request.user_role() = 'faculty'
        OR (
            request.user_role() = ANY('{student,ta}'::text[])
            AND (
                submitter_user_id = request.user_id()
                OR data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id)
            )
        )
    )
    WITH CHECK (
        request.user_role() = 'faculty'
        OR (
            request.user_role() = ANY('{student,ta}'::text[])
            AND submitter_user_id = request.user_id()
            AND data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id)
        )
    );

CREATE POLICY assignment_field_submission_delete_policy
    ON data.assignment_field_submission
    FOR DELETE
    TO api
    USING (request.user_role() = 'faculty');

-- student users can select from this view. The RLS will
-- limit them to viewing their own assignment_field_submissions.
grant select, insert, update on api.assignment_field_submissions to student, ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.assignment_field_submissions to faculty;
-- grant select, insert, update, delete on api.assignment_field_submissions to faculty;
