-- The `team` table is used to define groups of users.
-- Some of the assignments in class will be submitted
-- as a team, hence our need to track who is on what team.
CREATE TABLE IF NOT EXISTS team (
    nickname VARCHAR(50) UNIQUE NOT NULL PRIMARY KEY,
    CONSTRAINT valid_team_nickname
        CHECK (nickname ~ '^[\w]{2,20}-[\w]{2,20}$'),
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at)
);

-- Now that we've created the team table, add the `team_nickname`
-- foreign key to the user table. The `ON UPDATE CASCADE` means 
-- that this column will change if the `team.nickname` column
-- to which is points changes. That is, we can change a team's
-- name and it will be changed in the `data.user` table automatically.
ALTER TABLE "user"
    ADD COLUMN team_nickname VARCHAR(50)
    REFERENCES team
    ON UPDATE CASCADE;

-- Update the `updated_at` column when the team is changed.
CREATE TRIGGER tg_team_update_timestamps
    BEFORE INSERT OR UPDATE
    ON team
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();