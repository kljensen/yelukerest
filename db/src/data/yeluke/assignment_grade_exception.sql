
CREATE TABLE IF NOT EXISTS assignment_grade_exception (
    id INT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    assignment_slug TEXT CHECK (char_length(assignment_slug) < 100),
    is_team BOOLEAN NOT NULL,
    FOREIGN KEY (assignment_slug, is_team)
        REFERENCES assignment(slug, is_team)
        ON UPDATE CASCADE,
    user_id INT
        REFERENCES "user"(id)
        ON UPDATE CASCADE,
    team_nickname TEXT
        CHECK (char_length(team_nickname) < 50)
        REFERENCES team(nickname)
        ON UPDATE CASCADE,
    CONSTRAINT matches_assignment_is_team CHECK (
        (is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL))
        OR
        (NOT is_team AND (team_nickname IS NULL) AND (user_id IS NOT NULL))
    ),
    fractional_credit DECIMAL NOT NULL DEFAULT 1
        CHECK (fractional_credit >= 0 AND fractional_credit <= 1),
    closed_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at)
);

DROP INDEX IF EXISTS assignment_grade_exception_unique_user;
DROP INDEX IF EXISTS assignment_grade_exception_unique_team;
CREATE UNIQUE INDEX assignment_grade_exception_unique_user ON assignment_grade_exception (assignment_slug, user_id) WHERE is_team=FALSE;
CREATE UNIQUE INDEX assignment_grade_exception_unique_team ON assignment_grade_exception (assignment_slug, team_nickname) WHERE is_team=TRUE;


CREATE OR REPLACE FUNCTION fill_assignment_grade_exception_defaults()
RETURNS TRIGGER AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM api.assignments
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';


DROP TRIGGER IF EXISTS tg_assignment_grade_exception_default ON assignment_grade_exception;
CREATE TRIGGER tg_assignment_grade_exception_default
    BEFORE INSERT OR UPDATE
    ON assignment_grade_exception
    FOR EACH ROW
EXECUTE PROCEDURE fill_assignment_grade_exception_defaults();
