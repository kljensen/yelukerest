create or replace view quiz_grade_exceptions as
    select * from data.quiz_grade_exception;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `user` table should have RLS becuase students should not
-- see each others user grades.
alter view quiz_grade_exceptions owner to api;

-- A view that adds information about the time by which 
-- quiz submission must be completed.
create or replace view quiz_submissions_info as
    select
        qs.*,
        -- This is a little bit redundant...Here we're checking if there is still time 
        -- for the user to submit a quiz answer. This takes into account any extension
        -- they received for this quiz.
        (q.is_draft = False AND q.open_at < current_timestamp AND current_timestamp < LEAST(GREATEST(q.closed_at, qge.closed_at), qs.created_at + q.duration)) AS is_open,
        LEAST(GREATEST(q.closed_at, qge.closed_at), qs.created_at + q.duration) as closed_at
    FROM
        api.quiz_submissions qs
        JOIN api.quizzes q ON qs.quiz_id = q.id
        LEFT JOIN api.quiz_grade_exceptions qge ON (q.id = qge.quiz_id AND qs.user_id = qge.user_id)
    ;
alter view quiz_submissions_info owner to api;
