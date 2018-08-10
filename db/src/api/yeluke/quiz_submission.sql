create or replace view quiz_submissions as
    select * from data.quiz_submission;

-- A view that adds information about the time by which 
-- quiz submission must be completed.
create or replace view quiz_submissions_info as
    select
        qs.*,
        -- This is a little bit redundant...
        (q.is_open AND current_timestamp < LEAST(q.closed_at, qs.created_at + q.duration)) AS is_open,
        LEAST(q.closed_at, qs.created_at + q.duration) as closed_at
    FROM
        api.quiz_submissions qs JOIN api.quizzes q
        ON qs.quiz_id = q.id
    ;

-- It is important to set the correct owner so the RLS policy kicks in.
alter view quiz_submissions owner to api;
alter view quiz_submissions_info owner to api;
