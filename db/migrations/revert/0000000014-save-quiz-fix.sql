START TRANSACTION;

SET search_path = api, pg_catalog;


CREATE OR REPLACE FUNCTION save_quiz(quiz_id integer, quiz_question_option_ids integer[]) RETURNS SETOF data.quiz_answer
    LANGUAGE plpgsql
    AS $_$
BEGIN
    -- Functions are executed in a transaction.
    -- Delete all quiz_answers for this user's quiz_submission for this quiz_id.
    DELETE FROM api.quiz_answers qa WHERE qa.quiz_id = $1 AND qa.user_id = request.user_id();
    -- Insert the submitted quiz answers.
    INSERT INTO api.quiz_answers(quiz_question_option_id, user_id, quiz_id) select unnest($2), request.user_id(), $1;
    -- Return all quiz answers for this quiz_id.
    RETURN QUERY
        SELECT * FROM api.quiz_answers qa WHERE qa.quiz_id = $1;
END; $_$;

COMMIT TRANSACTION;
