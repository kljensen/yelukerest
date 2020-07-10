CREATE TABLE IF NOT EXISTS grade_snapshot (
    slug TEXT PRIMARY KEY
        CHECK (slug ~ '^[a-z0-9-]+$' AND char_length(slug) < 60),
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at)
);

CREATE OR REPLACE FUNCTION fill_grade_snapshot_defaults()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';


DROP TRIGGER IF EXISTS tg_grade_snapshot_default ON grade_snapshot;
CREATE TRIGGER tg_grade_snapshot_default
    BEFORE INSERT OR UPDATE
    ON grade_snapshot
    FOR EACH ROW
EXECUTE PROCEDURE fill_grade_snapshot_defaults();
