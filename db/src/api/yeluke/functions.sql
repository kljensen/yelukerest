CREATE OR REPLACE FUNCTION delete_quiz_question(integer, text)
RETURNS
TABLE (
    num_deleted_answers int,
    num_deleted_question_options int,
    num_deleted_questions int
)
AS $$
    WITH answer_details as (
        -- Get a full list of answers, options, and questions
        SELECT
            qq.quiz_id,
            qq.id quiz_question_id,
            qq.slug quiz_question_slug,
            qqo.id quiz_question_option_id
        FROM
            data.quiz_answer qa
            JOIN data.quiz_question_option qqo ON qa.quiz_question_option_id = qqo.id
            JOIN data.quiz_question qq ON qq.id = qqo.quiz_question_id
        WHERE
            -- Match only the input arguments
            qq.quiz_id = $1 and qq.slug = $2
    ), deleted_answers as (
        DELETE FROM data.quiz_answer
        using answer_details where
        quiz_answer.quiz_question_option_id = answer_details.quiz_question_option_id
        returning *
    ), deleted_question_options as (
        DELETE FROM data.quiz_question_option
        using answer_details where
        quiz_question_option.id = answer_details.quiz_question_option_id
        returning *
    ), deleted_questions as (
        DELETE FROM data.quiz_question
        using answer_details where
        quiz_question.id = answer_details.quiz_question_id
        returning *
    )
    select
        (select count(*) from deleted_answers) as num_deleted_answers,
        (select count(*) from deleted_question_options) as num_deleted_question_options,
        (select count(*) from deleted_questions) as num_deleted_questions
    ;
$$ LANGUAGE SQL;

-- Returns like
-- 
-- │ num_deleted_answers │ num_deleted_question_options │ num_deleted_questions │
-- ├─────────────────────┼──────────────────────────────┼───────────────────────┤
-- │                   3 │                            2 │                     1 │


COMMENT ON FUNCTION delete_quiz_question (integer, text) IS 'Deletes quiz_answers, quiz_question_options, and quiz_question for quiz question matching quiz_id and slug arguments';
revoke all privileges on function delete_quiz_question(integer, text) from public;


CREATE OR REPLACE FUNCTION delete_quiz_question_option(integer, text, text)
RETURNS
TABLE (
    num_deleted_answers int,
    num_deleted_question_options int
)
AS $$
    WITH answer_details as (
        -- Get a full list of answers, options, and questions
        SELECT
            qq.quiz_id,
            qq.id quiz_question_id,
            qq.slug quiz_question_slug,
            qqo.id quiz_question_option_id
        FROM
            data.quiz_answer qa
            JOIN data.quiz_question_option qqo ON qa.quiz_question_option_id = qqo.id
            JOIN data.quiz_question qq ON qq.id = qqo.quiz_question_id
        WHERE
            -- Match only the input arguments
            qq.quiz_id = $1 and qq.slug = $2 and qqo.slug = $3
    ), deleted_answers as (
        DELETE FROM data.quiz_answer
        using answer_details where
        quiz_answer.quiz_question_option_id = answer_details.quiz_question_option_id
        returning *
    ), deleted_question_options as (
        DELETE FROM data.quiz_question_option
        using answer_details where
        quiz_question_option.id = answer_details.quiz_question_option_id
        returning *
    )
    select
        (select count(*) from deleted_answers) as num_deleted_answers,
        (select count(*) from deleted_question_options) as num_deleted_question_options
    ;
$$ LANGUAGE SQL;

-- Returns like
-- 
-- │ num_deleted_answers │ num_deleted_question_options │ num_deleted_questions │
-- ├─────────────────────┼──────────────────────────────┼───────────────────────┤
-- │                   3 │                            2 │                     1 │


COMMENT ON FUNCTION delete_quiz_question_option (integer, text, text) IS 'Deletes quiz_answers for a quiz_question_options for quiz question option matching quiz_id question slug and quiz question option slug arguments';
revoke all privileges on function delete_quiz_question_option(integer, text, text) from public;
