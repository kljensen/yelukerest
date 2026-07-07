create or replace view quiz_grade_exceptions as
    select * from data.quiz_grade_exception;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `user` table should have RLS becuase students should not
-- see each others user grades.
alter view quiz_grade_exceptions owner to api;

-- A compatibility view for existing clients. Quizzes are now paper-only, so
-- submissions are never open for online answer editing.
create or replace view quiz_submissions_info as
    select
        qs.*,
        false AS is_open,
        COALESCE(qge.closed_at, q.closed_at) as closed_at
    FROM
        api.quiz_submissions qs
        JOIN api.quizzes q ON qs.quiz_id = q.id
        LEFT JOIN api.quiz_grade_exceptions qge ON (q.id = qge.quiz_id AND qs.user_id = qge.user_id)
    ;
alter view quiz_submissions_info owner to api;
