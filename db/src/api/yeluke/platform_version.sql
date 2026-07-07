create or replace view platform_version as
    select
        'yelukerest'::text as platform,
        1::integer as platform_compatibility_version,
        2::integer as schema_compatibility_version,
        5::integer as admin_api_version;

alter view platform_version owner to api;

COMMENT ON VIEW platform_version IS
    'Single-row compatibility metadata for course admin preflight checks';
COMMENT ON COLUMN platform_version.platform IS
    'Platform identifier expected by course admin tooling';
COMMENT ON COLUMN platform_version.platform_compatibility_version IS
    'Integer compatibility version for Yelukerest platform behavior';
COMMENT ON COLUMN platform_version.schema_compatibility_version IS
    'Integer compatibility version for database schema/API shape';
COMMENT ON COLUMN platform_version.admin_api_version IS
    'Integer compatibility version for generic admin API operations';
