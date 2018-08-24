START TRANSACTION;

SET search_path = public, pg_catalog;

REVOKE ta FROM authenticator;
DROP ROLE IF EXISTS ta;

COMMIT TRANSACTION;
