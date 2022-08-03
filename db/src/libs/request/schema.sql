DROP SCHEMA IF EXISTS request CASCADE;

CREATE SCHEMA request;

GRANT usage ON SCHEMA request TO public;

CREATE OR REPLACE FUNCTION request.user_role ()
    RETURNS text
    AS $$
    SELECT
        coalesce(current_setting('request.jwt.claim.role', TRUE), (current_setting('request.jwt.claims', TRUE)::json ->> 'role'));

$$ STABLE
LANGUAGE sql;

CREATE OR REPLACE FUNCTION request.app_name ()
    RETURNS text
    AS $$
    SELECT
        coalesce(current_setting('request.jwt.claim.app_name', TRUE), (current_setting('request.jwt.claims', TRUE)::json ->> 'app_name'));

$$ STABLE
LANGUAGE sql;

CREATE OR REPLACE FUNCTION request.user_id_as_text ()
    RETURNS text
    AS $$
    SELECT
        coalesce(current_setting('request.jwt.claim.user_id', TRUE), (current_setting('request.jwt.claims', TRUE)::json ->> 'user_id'));

$$ STABLE
LANGUAGE sql;

CREATE OR REPLACE FUNCTION request.user_id ()
    RETURNS int
    AS $$
    SELECT
        CASE request.user_id_as_text ()
        WHEN '' THEN
            0
        ELSE
            request.user_id_as_text ()::int
        END;

$$ STABLE
LANGUAGE sql;

