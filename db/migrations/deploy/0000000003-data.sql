START TRANSACTION;

SET search_path = public, pg_catalog;

CREATE TYPE _time_trial_type AS (
	a_time numeric
);

SET search_path = api, pg_catalog;

DROP VIEW todos;

SET search_path = data, pg_catalog;

DROP TRIGGER tg_quiz_submission_default ON quiz_submission;

ALTER TABLE quiz_submission
	ALTER COLUMN user_id SET DEFAULT request.user_id();

CREATE OR REPLACE FUNCTION fill_answer_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.quiz_id IS NULL) THEN
        SELECT quiz_id INTO NEW.quiz_id
        FROM api.quiz_question_options
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
    IF (NEW.user_id IS NULL AND NOT NEW.is_team ) THEN
        NEW.user_id = request.user_id();
    END IF;
    IF (NEW.submitter_user_id IS NULL ) THEN
        NEW.submitter_user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fill_quiz_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.user_id IS NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;

CREATE TRIGGER tg_quiz_submission_default
	BEFORE INSERT OR UPDATE ON quiz_submission
	FOR EACH ROW
	EXECUTE PROCEDURE fill_quiz_submission_defaults();

COMMIT TRANSACTION;
