-- Revert yelukerest:data from pg

BEGIN;

-- XXX Add DDLs here.
TRUNCATE settings.secrets;

COMMIT;
