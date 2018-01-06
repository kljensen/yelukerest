CREATE TYPE participation_enum AS ENUM('absent', 'attended', 'contributed', 'led');

CREATE TABLE IF NOT EXISTS engagement (
    user_id INT REFERENCES "user"(id) ON DELETE CASCADE,
    meeting_id INT REFERENCES meeting(id) ON DELETE CASCADE, 
    participation participation_enum NOT NULL,
    -- We are not going to have a constraint that the 
    -- `created_at` be after the `meeting_id.begins_at` because
    -- some students will have an excused absence in advance
    -- of a class and we want to record those students as
    -- present.
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    PRIMARY KEY(user_id, meeting_id)
);CREATE TRIGGER tg_engagement_update_timestamps
    BEFORE INSERT OR UPDATE
    ON engagement
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();