-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.

-- Browser sessions for authapp, kept in PostgreSQL (issue #365).
--
-- authapp used the SCS in-memory store, so every container recreate threw away
-- every session. CAS re-established most of them with a silent redirect, and
-- that is what made it worth fixing rather than tolerable: a deploy was
-- user-visible, and "I got logged out" stopped being a signal anyone chased.
-- A second authenticated origin makes one person hold two sessions and lose
-- both.
--
-- Postgres rather than Redis: the instance is already running, ~60 users
-- produce a few hundred rows, and a session table is the only thing a new
-- Redis would carry.
--
-- The column names and types below are not ours to choose. They are the
-- literal SQL of github.com/alexedwards/scs/postgresstore, so renaming a
-- column breaks authapp at runtime rather than at deploy time. verify.sql
-- pins the shape for that reason.

-- The role authapp logs in as has to exist before this runs, and this
-- migration cannot create it: roles are cluster-wide while migrations are
-- per-database, and yelukerest_migrator is deliberately NOCREATEROLE
-- (bin/provision-db.sh). Every login role in this system is provisioned
-- outside the migration graph for that reason -- Hydra's is
-- hydra/sql/create-hydra-db.sh, authapp's is
-- authapp/sql/create-authapp-db-role.sh. Keeping it there is also what keeps
-- the password out of a checked-in file.
--
-- Failing here rather than skipping the grants: a deploy that quietly produced
-- a table no one can write would surface as a login loop in production, hours
-- later and nowhere near the cause.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authapp') THEN
        RAISE EXCEPTION 'role "authapp" does not exist'
            USING HINT = 'run authapp/sql/create-authapp-db-role.sh once per cluster before deploying this migration';
    END IF;
END;
$$;

CREATE TABLE data.authapp_session (
    token TEXT PRIMARY KEY,
    data BYTEA NOT NULL,
    expiry TIMESTAMPTZ NOT NULL
);

-- Serves the cleanup pass, which deletes by expiry every five minutes. Lookups
-- go through the primary key, so this index exists for the delete alone.
CREATE INDEX authapp_session_expiry_idx ON data.authapp_session (expiry);

ALTER TABLE data.authapp_session OWNER TO yelukerest_migrator;

COMMENT ON TABLE data.authapp_session IS
    'Opaque browser sessions for authapp. Readable only by the authapp role: no api view exposes it and no application role holds a privilege on it.';
COMMENT ON COLUMN data.authapp_session.token IS
    'The session cookie value itself. Anyone who can read this column can impersonate the session, which is why nothing but the authapp role may.';
COMMENT ON COLUMN data.authapp_session.data IS
    'Gob-encoded session payload written by SCS. Opaque to the database.';
COMMENT ON COLUMN data.authapp_session.expiry IS
    'When the session stops being honoured. Rows past it are deleted by authapp''s cleanup goroutine.';

-- No row-level security: every row is reachable by exactly one bearer token
-- and there is no second party to distinguish, so the privilege grant below is
-- the whole access decision. RLS here would only add a policy that says true.
GRANT USAGE ON SCHEMA data TO authapp;
GRANT SELECT, INSERT, UPDATE, DELETE ON data.authapp_session TO authapp;
