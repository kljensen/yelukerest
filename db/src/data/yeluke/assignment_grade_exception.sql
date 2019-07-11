
CREATE TABLE IF NOT EXISTS assignment_grade_exception (
    -- Assignment: team, not team
    -- Quiz
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
    CONSTRAINT matches_assignment_is_team CHECK (
        (is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL))
        OR
        (NOT is_team AND (team_nickname IS NULL) AND (user_id IS NOT NULL))
    ),
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

DROP TRIGGER IF EXISTS tg_assignment_grade_exception_default ON assignment_grade_exception;
CREATE TRIGGER tg_assignment_grade_exception_default
    BEFORE INSERT OR UPDATE
    ON assignment_grade_exception
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();