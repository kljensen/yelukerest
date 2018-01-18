START TRANSACTION;

SET search_path = public, pg_catalog;

DROP TYPE _time_trial_type;

SET search_path = api, pg_catalog;

CREATE VIEW todos AS
	SELECT todo.id,
    todo.todo,
    todo.private,
    (todo.owner_id = request.user_id()) AS mine
   FROM data.todo;

ALTER VIEW todos OWNER TO api;
REVOKE ALL ON TABLE todos FROM student;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE todos TO student;

SET search_path = data, pg_catalog;

DROP TRIGGER tg_quiz_submission_default ON quiz_submission;

DROP FUNCTION fill_quiz_submission_defaults();

ALTER TABLE quiz_submission
	ALTER COLUMN user_id DROP DEFAULT;

CREATE OR REPLACE FUNCTION fill_answer_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.quiz_id IS NULL) THEN
        SELECT quiz_id INTO NEW.quiz_id
        FROM quiz_question_option
        WHERE id = NEW.quiz_question_option_id;
    END IF;
    IF (NEW.user_id IS NULL and request.user_id() IS NOT NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fill_assignment_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM api.assignments
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;

CREATE TRIGGER tg_quiz_submission_default
	BEFORE INSERT OR UPDATE ON quiz_submission
	FOR EACH ROW
	EXECUTE PROCEDURE update_updated_at_column();

COMMIT TRANSACTION;
