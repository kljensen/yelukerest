
CREATE TABLE IF NOT EXISTS assignment_grade (
    assignment_slug VARCHAR(100) NOT NULL,
    points_possible smallint NOT NULL,
    assignment_submission_id INT PRIMARY KEY,
    points REAL NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT points_in_range CHECK (points >= 0 AND points <= points_possible),
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    -- Must point to assignment
    FOREIGN KEY (assignment_slug, points_possible)
        REFERENCES assignment(slug, points_possible)
        ON UPDATE CASCADE,
    -- Must point to a assignment submission
    FOREIGN KEY (assignment_submission_id, assignment_slug)
        REFERENCES assignment_submission(id, assignment_slug)
        ON UPDATE CASCADE
);

CREATE OR REPLACE FUNCTION fill_assignment_grade_defaults()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT ass_sub.assignment_slug INTO NEW.assignment_slug
        FROM api.assignment_submissions as ass_sub
        WHERE ass_sub.id = NEW.assignment_submission_id;
    END IF;
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM api.assignments
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';


DROP TRIGGER IF EXISTS tg_assignment_grade_default ON assignment_grade;
CREATE TRIGGER tg_assignment_grade_default
    BEFORE INSERT OR UPDATE
    ON assignment_grade
    FOR EACH ROW
EXECUTE PROCEDURE fill_assignment_grade_defaults();
