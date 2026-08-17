create or replace view platform_version as
    select
        'yelukerest'::text as platform,
        1::integer as platform_compatibility_version,
        4::integer as schema_compatibility_version,
        8::integer as admin_api_version;

alter view platform_version owner to api;

COMMENT ON VIEW platform_version IS
    'Single-row compatibility metadata for course admin preflight checks';
COMMENT ON COLUMN platform_version.platform IS
    'Platform identifier expected by course admin tooling';
COMMENT ON COLUMN platform_version.platform_compatibility_version IS
    'Integer compatibility version for Yelukerest platform behavior';
COMMENT ON COLUMN platform_version.schema_compatibility_version IS
    'Integer identifying the api schema shape. Check for membership in the set of shapes the client supports, NOT with >=: a shape can lose columns and views, and version 4 did. A client pinned to >= 3 would pass its own preflight against 4 and then fail on its first request.';
COMMENT ON COLUMN platform_version.admin_api_version IS
    'Integer compatibility version for generic admin API operations. Only ever grows -- each bump adds an RPC without removing one -- so >= is the correct check.';
