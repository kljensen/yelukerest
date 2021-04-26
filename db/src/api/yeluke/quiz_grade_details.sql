-- Here I'm creating a view that has one row per
-- user per quiz and includes rows for quizzes even
-- if a user did not complete the quiz. Then I do
-- some JSON aggregation so that I can capture all
-- the users answers to quiz questions.
CREATE OR REPLACE VIEW quiz_grade_details AS

-- Aggregate up the quiz question options to the question level first
WITH graded_questions AS (
    SELECT
        user_id,
        quiz_id,
        has_submission,
        quiz_question_id,
        quiz_question_body,
        extension_deadline,
        fractional_credit,
        bool_and(is_selected = is_correct) answered_correctly,
        COALESCE(
            json_agg(
                json_build_object(
                    'id', quiz_question_option_id,
                    'body', quiz_question_option_body,
                    'is_selected', is_selected,
                    'is_correct', is_correct
                )
                ORDER BY quiz_question_option_id
            -- If this quiz question has no quiz question options, we should
            -- have an empty array instead of JSON object with NULL keys.
            ) FILTER (WHERE quiz_question_option_body IS NOT NULL), '[]'
        ) AS options
    FROM
        api.quiz_answer_details
    GROUP BY
        user_id,
        quiz_id,
        has_submission,
        quiz_question_id,
        quiz_question_body,
        extension_deadline,
        fractional_credit
    ORDER BY
        quiz_id,
        user_id,
        quiz_question_id
),
graded_quizzes AS (
    SELECT
        user_id,
        quiz_id,
        has_submission,
        extension_deadline,
        fractional_credit,
        count(*) num_questions,
        count(*) FILTER (WHERE answered_correctly) num_correct,
        count(*) FILTER (WHERE NOT answered_correctly) num_wrong,
        COALESCE(
            json_agg(
                json_build_object(
                    'id', quiz_question_id,
                    'body', quiz_question_body,
                    'answered_correctly', answered_correctly,
                    'options', options)
            ) FILTER (WHERE quiz_question_body IS NOT NULL), '[]'
        ) AS questions
    FROM
        graded_questions
    GROUP BY
        user_id,
        quiz_id,
        has_submission,
        extension_deadline,
        fractional_credit
)
SELECT
    user_id,
    u.name user_name,
    u.nickname user_nickname,
    u.email user_email,
    quiz.id quiz_id,
    meeting_slug,
    has_submission,
    extension_deadline,
    num_questions,
    num_correct,
    num_wrong,
    fractional_credit,
    points_possible,
    fractional_credit::float * points_possible::float * num_correct::float / num_questions::float points,
    questions
FROM
    graded_quizzes
    JOIN data.quiz ON quiz.id = graded_quizzes.quiz_id
    JOIN data.user u ON user_id = u.id
ORDER BY
    quiz_id,
    user_id;

alter view quiz_grade_details owner to api;
