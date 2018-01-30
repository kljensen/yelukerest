
CREATE TABLE IF NOT EXISTS assignment (
    slug VARCHAR(100) PRIMARY KEY
        CHECK (slug ~ $$^[a-z0-9-]+$$),
    -- Number of points possible on this assignment.
    points_possible smallint NOT NULL
        CHECK (points_possible >= 0),
    -- If this assignment is still being worked on by the faculty
    is_draft BOOLEAN NOT NULL DEFAULT true NOT NULL,
    is_markdown BOOLEAN DEFAULT false,
    is_team BOOLEAN DEFAULT false,
    title VARCHAR(100) NOT NULL,
    body text NOT NULL,
    -- The time after which students may not
    -- take the assignment
    closed_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    UNIQUE(slug, is_team), -- For foreign keys
    UNIQUE(slug, points_possible)
);


DROP TRIGGER IF EXISTS tg_assignment_default ON assignment;
CREATE TRIGGER tg_assignment_default
    BEFORE INSERT OR UPDATE
    ON assignment
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();