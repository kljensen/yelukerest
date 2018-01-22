START TRANSACTION;

SET search_path = data, pg_catalog;

DROP TRIGGER tg_assignment_field_submission_default ON assignment_field_submission;

DROP FUNCTION fill_assignment_field_submission_defaults();

CREATE TRIGGER tg_assignment_field_submission_default
	BEFORE INSERT OR UPDATE ON assignment_field_submission
	FOR EACH ROW
	EXECUTE PROCEDURE update_updated_at_column();

COMMIT TRANSACTION;
