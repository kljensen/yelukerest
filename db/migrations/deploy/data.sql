
-- This file was created automatically by the create-initial-migrations.sh
-- script. DO NOT EDIT BY HAND.

BEGIN;
\set jwt_secret `echo $JWT_SECRET`

-- Raise an exception if jwt_secret is not at least 32 characters long.
DO $$ 
BEGIN
  IF LENGTH(current_setting('jwt_secret')) < 32 THEN
    RAISE EXCEPTION 'jwt_secret must be at least 32 characters long';
  END IF;
END $$;

SET search_path = settings, pg_catalog, public;

INSERT INTO secrets (key, value) VALUES ('jwt_lifetime','3600');
INSERT INTO secrets (key, value) VALUES ('auth.default-role','anonymous');
INSERT INTO secrets (key, value) VALUES ('auth.data-schema','data');
INSERT INTO secrets (key, value) VALUES ('auth.api-schema','api');
INSERT INTO secrets (key, value) VALUES ('jwt_secret',:'jwt_secret');

COMMIT;
