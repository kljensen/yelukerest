-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- Nothing here touched a row of data.user_secret's schema or its contents, so
-- this restores the database exactly: the four functions go, the trigger body
-- goes back to what roadmap-9-admin-api left, and admin_api_version returns to
-- 8. Secrets already written by the RPCs stay written, which is correct -- they
-- are ordinary rows a faculty member could have inserted through the view.

DROP FUNCTION IF EXISTS api.upsert_user_secrets(jsonb, boolean);
DROP FUNCTION IF EXISTS api.upsert_team_secrets(jsonb, boolean);
DROP FUNCTION IF EXISTS data.check_user_secret_batch(jsonb, text, text);
DROP FUNCTION IF EXISTS data.user_secret_input_bounds();

-- Back to the bare current_timestamp this migration replaced. It reintroduces
-- the #308 hole on data.user_secret, which is what reverting means.
SET search_path = data, public;

CREATE OR REPLACE FUNCTION fill_user_secret_defaults()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

SET search_path = api, public;

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

-- The reverse of the deploy's notification, and needed for the same reason in
-- the other direction: without it PostgREST keeps two functions in its schema
-- cache that no longer exist, and answers calls to them with a 500 from the
-- database rather than the 404 that is now true.
NOTIFY pgrst, 'reload schema';
