-- Verify yelukerest:user_secrets on pg

BEGIN;

SELECT * FROM data.user_secret;

ROLLBACK;
