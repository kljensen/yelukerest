select settings.set('auth.data-schema', current_schema);

CREATE OR REPLACE function clean_user_fields() returns trigger as $$
BEGIN
    NEW.email := lower(NEW.email);
    NEW.netid := lower(NEW.netid);
    NEW.nickname := lower(NEW.nickname);
    NEW.updated_at = current_timestamp;
    return NEW;
END;
$$ language plpgsql;

CREATE TABLE IF NOT EXISTS "user" (
    id SERIAL PRIMARY KEY,
    -- Notice that the team_nickname column is missing here, it will
    -- be added later once we define the `data.team` table.
    email VARCHAR(100) UNIQUE
        CHECK ( email ~ '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$' ),
    netid VARCHAR(10) UNIQUE NOT NULL
        CHECK (netid ~ '^[a-z]+[0-9]+$'),
    name VARCHAR(100),
    lastName VARCHAR(100),
    organization VARCHAR(200),
    known_as VARCHAR(50),
    nickname VARCHAR(50) UNIQUE NOT NULL
        CHECK (nickname ~ '^[\w]{2,20}-[\w]{2,20}$'),
    "role" user_role NOT NULL DEFAULT settings.get('auth.default-role')::user_role,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
	CHECK (updated_at >= created_at)
);

-- trigger (updated_at)
CREATE TRIGGER tg_users_default
    BEFORE INSERT OR UPDATE
    ON "user"
    FOR EACH ROW
EXECUTE PROCEDURE clean_user_fields();