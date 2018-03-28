START TRANSACTION;

SET search_path = data, pg_catalog;

CREATE OR REPLACE FUNCTION fill_assignment_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM api.assignments
        WHERE slug = NEW.assignment_slug;
    END IF;
    -- Set default user_id from request credentials
    IF (NEW.user_id IS NULL AND NOT NEW.is_team ) THEN
        NEW.user_id = request.user_id();
    END IF;
    -- Set default submitter_user_id from request credentials
    IF (NEW.submitter_user_id IS NULL ) THEN
        NEW.submitter_user_id = request.user_id();
    END IF;
    -- Set default team_nickname from user table
    IF (NEW.is_team AND NEW.team_nickname IS NULL) THEN
        SELECT team_nickname INTO NEW.team_nickname
        FROM api.users
        WHERE api.users.id = NEW.submitter_user_id;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;

COMMIT TRANSACTION;
