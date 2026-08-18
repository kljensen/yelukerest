-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- This drops data.assignment_repository_snapshot, so it drops its rows, and
-- unlike the repository mapping those rows are *not* reconstructible. The
-- mapping also exists on the forge; a capture of what HEAD was at a deadline
-- that has already passed exists nowhere else, and the bundles it points at
-- become files in a bucket that nothing names. Revert this only before real
-- captures have run, or take a dump of the table first and mean it.

DROP VIEW IF EXISTS api.assignment_repository_snapshots_due;
DROP VIEW IF EXISTS api.assignment_repository_snapshots;
DROP TABLE IF EXISTS data.assignment_repository_snapshot;

-- Back to the shape that predates this migration. admin_api_version was not
-- touched by the deploy and is left where it stands.
CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::integer AS platform_compatibility_version,
        5::integer AS schema_compatibility_version,
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

-- PostgREST would otherwise keep serving cached snapshot views that no longer
-- exist, turning a clean 404 into a 500 from the database.
NOTIFY pgrst, 'reload schema';
