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
    email TEXT UNIQUE
        CHECK ( email ~ '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$' and char_length(email) < 100),
    netid TEXT UNIQUE NOT NULL
        CHECK (netid ~ '^[a-z]+[0-9]+$' AND char_length(netid) < 10),
    name TEXT CHECK (char_length(name) < 100),
    lastname TEXT CHECK (char_length(lastname) < 100),
    organization TEXT CHECK (char_length(organization) < 200),
    known_as TEXT CHECK (char_length(known_as) < 50),
    nickname TEXT UNIQUE NOT NULL
        CHECK (nickname ~ '^[\w]{2,20}-[\w]{2,20}$' AND char_length(nickname) < 50),
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
