-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- Reverting logs out everyone currently signed in and puts authapp back on the
-- in-memory store, where the next container recreate does it again. This
-- exists so the migration is reversible, not as a routine operation.

DROP TABLE IF EXISTS data.authapp_session;

REVOKE USAGE ON SCHEMA data FROM authapp;

-- The authapp role itself stays. Roles are cluster-wide but migrations are
-- per-database, so dropping it here would pull the credential out from under
-- every other database in the cluster that has this migration applied, and it
-- would invalidate the password an operator already put in .env. With the
-- table gone it grants access to nothing.
