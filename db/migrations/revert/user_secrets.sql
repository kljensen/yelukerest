-- Revert yelukerest:user_secrets from pg

BEGIN;

DROP policy IF EXISTS user_secret_access_policy on data.user_secret;
-- Cascade should delete views and triggers
DROP TABLE data.user_secret CASCADE;
DROP FUNCTION IF EXISTS fill_user_secret_defaults;

COMMIT;
