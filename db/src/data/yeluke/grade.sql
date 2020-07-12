CREATE TABLE IF NOT EXISTS grade (
    points REAL NOT NULL CHECK (points >= 0),
    snapshot_slug TEXT REFERENCES grade_snapshot(slug)
        ON UPDATE CASCADE NOT NULL,
    user_id INT REFERENCES "user"(id)
        ON UPDATE CASCADE NOT NULL,
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    UNIQUE(snapshot_slug, user_id)
);

CREATE OR REPLACE FUNCTION fill_grade_defaults()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';


DROP TRIGGER IF EXISTS tg_grade_default ON grade;
CREATE TRIGGER tg_grade_default
    BEFORE INSERT OR UPDATE
    ON grade
    FOR EACH ROW
EXECUTE PROCEDURE fill_grade_defaults();
