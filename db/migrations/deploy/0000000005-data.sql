START TRANSACTION;

SET search_path = data, pg_catalog;

DROP TRIGGER tg_assignment_field_submission_default ON assignment_field_submission;

CREATE OR REPLACE FUNCTION fill_assignment_field_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT assignment_slug INTO NEW.assignment_slug
        FROM api.assignment_fields
        WHERE id = NEW.assignment_field_id;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;

CREATE TRIGGER tg_assignment_field_submission_default
	BEFORE INSERT OR UPDATE ON assignment_field_submission
	FOR EACH ROW
	EXECUTE PROCEDURE fill_assignment_field_submission_defaults();

COMMIT TRANSACTION;
