-- Here I'm creating a view that has one row per
-- user per quiz_question_option or one row if 
-- there are no quiz_question_options for a quiz
-- (e.g. that quiz doesn't have questions yet)
CREATE OR REPLACE VIEW quiz_answer_details AS
SELECT
    "user".id user_id,
    quiz.id quiz_id,
    qge.closed_at AS extension_deadline,
    COALESCE(qge.fractional_credit, 1)::float AS fractional_credit,
    qs.quiz_id IS NOT NULL AS has_submission,
    qqo.quiz_question_id,
    qq.body quiz_question_body,
    qqo.id quiz_question_option_id,
    qqo.body quiz_question_option_body,
    qqo.is_correct,
    qa.quiz_question_option_id IS NOT NULL AS is_selected
FROM
    data.quiz
    CROSS JOIN data.user
    LEFT JOIN data.quiz_question_option qqo
        ON qqo.quiz_id = quiz.id
    LEFT JOIN data.quiz_answer qa
        ON qa.quiz_id = qqo.quiz_id
        AND qa.user_id = "user".id
        AND qa.quiz_question_option_id = qqo.id
    LEFT JOIN data.quiz_submission qs
        ON qs.quiz_id = qqo.quiz_id
        AND qs.user_id = "user".id
    LEFT JOIN data.quiz_grade_exception qge
        ON qge.quiz_id = qs.quiz_id
        AND qge.user_id = "user".id
    LEFT JOIN data.quiz_question qq ON qqo.quiz_question_id = qq.id
ORDER BY
    user_id,
    qqo.quiz_id,
    quiz_question_id,
    quiz_question_option_id;

