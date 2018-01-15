-- Revert app:0000000002-data from pg

BEGIN;

SET search_path = settings, pg_catalog;
TRUNCATE secrets;

COMMIT;
