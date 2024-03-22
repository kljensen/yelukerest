
-- This file was created automatically by the create-initial-migrations.sh
-- script. DO NOT EDIT BY HAND.

BEGIN;
\set jwt_secret `echo $JWT_SECRET`

SET search_path = settings, pg_catalog, public;

INSERT INTO secrets (key, value) VALUES ('jwt_lifetime','3600');
INSERT INTO secrets (key, value) VALUES ('auth.default-role','anonymous');
INSERT INTO secrets (key, value) VALUES ('auth.data-schema','data');
INSERT INTO secrets (key, value) VALUES ('auth.api-schema','api');
INSERT INTO secrets (key, value) VALUES ('jwt_secret',:'jwt_secret');

-- Check that jwt_secret is set and greater than 32 characters
DO $$ 
BEGIN
  IF (SELECT length(value) FROM secrets WHERE key = 'jwt_secret') < 32 THEN
    RAISE EXCEPTION 'jwt_secret must be set and greater than 32 characters';
  END IF;
END $$;

COMMIT;
