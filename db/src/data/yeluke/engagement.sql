CREATE TYPE participation_enum AS ENUM('absent', 'attended', 'contributed', 'led');

CREATE TABLE IF NOT EXISTS engagement (
    user_id INT REFERENCES "user"(id) ON DELETE CASCADE,
    meeting_id INT REFERENCES meeting(id) ON DELETE CASCADE, 
    participation participation_enum NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    PRIMARY KEY(user_id, meeting_id)
);