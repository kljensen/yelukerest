-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- This drops data.assignment_repository, so it drops its rows. That is honest
-- rather than lossless: the table is new here, nothing else references it, and
-- the mapping it holds is reconstructible from the forge, which is the one
-- place it also exists. Reverting after real provisioning has run means
-- re-reading the forge, not restoring a backup -- which is exactly the split
-- brain this table exists to end, so revert with that in mind.

DROP VIEW IF EXISTS api.assignment_repositories;
DROP TABLE IF EXISTS data.assignment_repository;

-- Back to the shape that predates this migration. admin_api_version was not
-- touched by the deploy and is left where it stands.
CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::integer AS platform_compatibility_version,
        4::integer AS schema_compatibility_version,
        9::integer AS admin_api_version;

ALTER VIEW api.platform_version OWNER TO api;

COMMENT ON VIEW api.platform_version IS
    'Single-row compatibility metadata for course admin preflight checks';
COMMENT ON COLUMN api.platform_version.platform IS
    'Platform identifier expected by course admin tooling';
COMMENT ON COLUMN api.platform_version.platform_compatibility_version IS
    'Integer compatibility version for Yelukerest platform behavior';
COMMENT ON COLUMN api.platform_version.schema_compatibility_version IS
    'Integer identifying the api schema shape. Check for membership in the set of shapes the client supports, NOT with >=: a shape can lose columns and views, and version 4 did. A client pinned to >= 3 would pass its own preflight against 4 and then fail on its first request.';
COMMENT ON COLUMN api.platform_version.admin_api_version IS
    'Integer compatibility version for generic admin API operations. Only ever grows -- each bump adds an RPC without removing one -- so >= is the correct check.';

-- PostgREST would otherwise keep serving a cached api.assignment_repositories
-- that no longer exists, turning a clean 404 into a 500 from the database.
NOTIFY pgrst, 'reload schema';
