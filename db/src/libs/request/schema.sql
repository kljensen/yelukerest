DROP SCHEMA IF EXISTS request CASCADE;

CREATE SCHEMA request;

GRANT usage ON SCHEMA request TO public;

CREATE OR REPLACE FUNCTION request.jwt_claim (claim text)
    RETURNS text
    STABLE
    LANGUAGE sql
    RETURN coalesce(
        nullif(current_setting('request.jwt.claim.' || claim, TRUE), ''),
        nullif((nullif(current_setting('request.jwt.claims', TRUE), '')::json ->> claim), '')
    );

CREATE OR REPLACE FUNCTION request.user_role ()
    RETURNS text
    STABLE
    LANGUAGE sql
    RETURN request.jwt_claim('role');

CREATE OR REPLACE FUNCTION request.app_name ()
    RETURNS text
    STABLE
    LANGUAGE sql
    RETURN request.jwt_claim('app_name');

CREATE OR REPLACE FUNCTION request.user_id_as_text ()
    RETURNS text
    STABLE
    LANGUAGE sql
    RETURN request.jwt_claim('user_id');

CREATE OR REPLACE FUNCTION request.user_id ()
    RETURNS int
    STABLE
    LANGUAGE sql
    RETURN
        CASE request.user_id_as_text()
        WHEN '' THEN
            0
        ELSE
            request.user_id_as_text()::int
        END;
