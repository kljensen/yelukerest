
-- Table `meeting` stores information about a single meeting of
-- our class, usually a lecture, but sometimes an exam, or even
-- a hack-a-thon.
CREATE TABLE IF NOT EXISTS meeting (
    title text NOT NULL CHECK (char_length(title) < 250),
    slug TEXT UNIQUE NOT NULL
        CHECK (slug ~ '^[a-z0-9-]+$' AND char_length(slug) < 60),
    summary TEXT,
    description TEXT NOT NULL,
    begins_at TIMESTAMP WITH TIME ZONE NOT NULL,
    duration INTERVAL NOT NULL,
    is_draft BOOLEAN NOT NULL DEFAULT false,

    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at)
);

-- trigger (updated_at)
DROP TRIGGER IF EXISTS tg_meeting_default ON meeting;
CREATE TRIGGER tg_meeting_default
    BEFORE INSERT OR UPDATE
    ON meeting
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();
