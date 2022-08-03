DROP SCHEMA IF EXISTS request CASCADE;

CREATE SCHEMA request;

GRANT usage ON SCHEMA request TO public;

CREATE OR REPLACE FUNCTION request.above_pg14 ()
    RETURNS bool
    AS $$
    SELECT
        current_setting('server_version_num')::int >= 140000;

$$ STABLE
LANGUAGE sql;

CREATE OR REPLACE FUNCTION request.user_id_as_text ()
    RETURNS text
    AS $$
    SELECT
        CASE WHEN request.above_pg14 () THEN
            current_setting('request.jwt.claims', TRUE)::json ->> 'user_id'
        ELSE
            current_setting('request.jwt.claim.user_id', TRUE)
        END;

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

CREATE OR REPLACE FUNCTION request.user_role ()
    RETURNS text
    AS $$
    SELECT
        CASE WHEN request.above_pg14 () THEN
            current_setting('request.jwt.claims', TRUE)::json ->> 'role'
        ELSE
            current_setting('request.jwt.claim.role', TRUE)
        END;

$$ STABLE
LANGUAGE sql;

CREATE OR REPLACE FUNCTION request.app_name ()
    RETURNS text
    AS $$
    SELECT
        CASE WHEN request.above_pg14 () THEN
            current_setting('request.jwt.claims', TRUE)::json ->> 'app_name'
        ELSE
            current_setting('request.jwt.claim.app_name', TRUE)
        END;

$$ STABLE
LANGUAGE sql;

