START TRANSACTION;

SET search_path = data, pg_catalog;

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

COMMIT TRANSACTION;
