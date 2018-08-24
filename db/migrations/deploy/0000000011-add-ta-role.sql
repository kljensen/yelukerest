START TRANSACTION;

SET search_path = public, pg_catalog;

DROP ROLE IF EXISTS ta;
CREATE ROLE ta;
GRANT ta TO authenticator;


COMMIT TRANSACTION;
