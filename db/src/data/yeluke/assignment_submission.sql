
CREATE TABLE IF NOT EXISTS assignment_submission (
    id SERIAL PRIMARY KEY,
    assignment_slug VARCHAR(100),
    is_team BOOLEAN,
    FOREIGN KEY (assignment_slug, is_team) REFERENCES assignment(slug, is_team)
        ON DELETE CASCADE ON UPDATE CASCADE,
    user_id INT REFERENCES "user"(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    team_nickname VARCHAR(50) REFERENCES team(nickname)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    submitter_user_id INT REFERENCES "user"(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE NOT NULL DEFAULT request.user_id(),
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    CONSTRAINT matches_assignment_is_team CHECK (
        (is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL))
        OR
        (NOT is_team AND (team_nickname IS NULL) AND (user_id IS NOT NULL))
    ),
    -- If a user creates an individual assignment submission,
    -- the user_id will need to match the sumbmitter_user_id
    CONSTRAINT submitter_matches_user_id CHECK(
        (is_team)
        OR
        (NOT is_team AND (user_id = submitter_user_id))
    ),
    UNIQUE(id, assignment_slug) -- For foreign keys\
);

-- Only one submission per team per assignment
CREATE UNIQUE INDEX assignment_submission_unique_team
    ON assignment_submission (team_nickname, assignment_slug)
    WHERE user_id IS NULL;
-- Only one submission per user per assignment
CREATE UNIQUE INDEX assignment_submission_unique_user
    ON assignment_submission (user_id, assignment_slug)
    WHERE team_nickname IS NULL;

CREATE OR REPLACE FUNCTION fill_assignment_submission_defaults()
RETURNS TRIGGER AS $$
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
    -- Set default submitter_user_id. This is done in 
    -- the table defaults, but we do it here so that
    -- we can fill in team nickname below.
    IF (NEW.submitter_user_id IS NULL ) THEN
        IF (request.user_id() IS NULL ) THEN
            IF (NEW.user_id IS NOT NULL) THEN
                NEW.submitter_user_id = NEW.user_id;
            END IF;
        ELSE
            NEW.submitter_user_id = request.user_id();
        END IF;
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
$$ language 'plpgsql';


DROP TRIGGER IF EXISTS tg_assignment_submission_default ON assignment_submission;
CREATE TRIGGER tg_assignment_submission_default
    BEFORE INSERT OR UPDATE
    ON assignment_submission
    FOR EACH ROW
EXECUTE PROCEDURE fill_assignment_submission_defaults();