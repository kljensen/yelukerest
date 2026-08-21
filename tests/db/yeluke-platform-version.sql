
SELECT plan(9);

SELECT view_owner_is(
    'api', 'platform_version', 'api',
    'api.platform_version view should be owned by the api role'
);

SELECT set_eq(
    $$
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'api'
        AND table_name = 'platform_version'
    $$,
    ARRAY[
        'platform',
        'platform_compatibility_version',
        'schema_compatibility_version',
        'admin_api_version'
    ],
    'api.platform_version should expose the expected columns'
);

SELECT table_privs_are(
    'api', 'platform_version', 'anonymous', ARRAY['SELECT'],
    'anonymous users should only be granted SELECT on api.platform_version'
);

SELECT table_privs_are(
    'api', 'platform_version', 'faculty', ARRAY['SELECT'],
    'faculty should only be granted SELECT on api.platform_version'
);

set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT results_eq(
    'SELECT count(*) FROM api.platform_version',
    ARRAY[1::bigint],
    'api.platform_version should expose exactly one row'
);

SELECT is(
    (SELECT platform FROM api.platform_version),
    'yelukerest',
    'api.platform_version should identify the platform'
);

SELECT is(
    (SELECT platform_compatibility_version FROM api.platform_version),
    1,
    'api.platform_version should expose the expected platform compatibility version'
);

-- Shape 6 adds api.assignment_repository_snapshots and
-- api.assignment_repository_snapshots_due (#22), on top of the
-- api.assignment_repositories that shape 5 added (#312). A course client that
-- runs the snapshotter declares {6}; one that reads none of those views
-- declares {4, 5, 6, 7}. This is an equality because it pins what the deployment
-- currently advertises, and it is meant to be revised deliberately by whichever
-- change next moves the shape.
SELECT is(
    (SELECT schema_compatibility_version FROM api.platform_version),
    7,
    'api.platform_version should expose the expected schema compatibility version'
);

SELECT is(
    (SELECT admin_api_version FROM api.platform_version),
    10,
    'api.platform_version should expose the expected admin API version'
);

SELECT * FROM finish();
