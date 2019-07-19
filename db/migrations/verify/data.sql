-- Verify yelukerest:data on pg

BEGIN;

DO $$
DECLARE
    result varchar;
BEGIN
   result := (SELECT value FROM settings.secrets WHERE key = 'jwt_lifetime');
   ASSERT result = '3600';
END $$;

ROLLBACK;
