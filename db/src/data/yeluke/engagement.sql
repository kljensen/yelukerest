CREATE TYPE participation_enum AS ENUM('absent', 'attended', 'contributed', 'led');

CREATE TABLE IF NOT EXISTS engagement (
    user_id INT REFERENCES "user"(id)
        ON DELETE CASCADE ON UPDATE CASCADE,
    meeting_slug VARCHAR(100) REFERENCES meeting(slug)
        ON DELETE CASCADE ON UPDATE CASCADE, 
    participation participation_enum NOT NULL,
    -- We are not going to have a constraint that the 
    -- `created_at` be after the `meeting_slug.begins_at` because
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
    PRIMARY KEY(user_id, meeting_slug)
);

-- Update the `updated_at` column when the engagement is changed.
DROP TRIGGER IF EXISTS tg_engagement_update_timestamps ON engagement;
CREATE TRIGGER tg_engagement_update_timestamps
    BEFORE INSERT OR UPDATE
    ON engagement
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();

create trigger engagement_rabbitmq_tg
after insert or update or delete on engagement
for each row execute procedure rabbitmq.on_row_change();