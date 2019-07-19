-- Verify yelukerest:init on pg

BEGIN;

-- XXX Add verifications here.
SELECT pg_catalog.has_schema_privilege('data', 'usage');

ROLLBACK;
