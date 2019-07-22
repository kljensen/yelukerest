-- Revert yelukerest:init from pg

BEGIN;

DROP SCHEMA api CASCADE;
DROP SCHEMA auth CASCADE;
DROP SCHEMA "data" CASCADE;
DROP SCHEMA pgjwt CASCADE;
DROP SCHEMA rabbitmq CASCADE;
DROP SCHEMA request CASCADE;
DROP SCHEMA settings CASCADE;


CREATE OR REPLACE FUNCTION public.safely_drop_role(rolename NAME) RETURNS TEXT AS
$$
BEGIN
    IF EXISTS (SELECT * FROM pg_roles WHERE rolname = rolename) THEN
        EXECUTE 'REASSIGN OWNED BY ' || quote_ident(rolename) || ' TO postgres';
        EXECUTE 'DROP OWNED BY ' || quote_ident(rolename);
        EXECUTE 'DROP ROLE IF EXISTS ' || quote_ident(rolename);
        RETURN format('DROPPED ''%I''', rolename);
    END IF;
END;
$$
LANGUAGE plpgsql;

SELECT public.safely_drop_role('authenticator');
SELECT public.safely_drop_role('anonymous');
SELECT public.safely_drop_role('api');
SELECT public.safely_drop_role('authapp');
SELECT public.safely_drop_role('faculty');
SELECT public.safely_drop_role('observer');
SELECT public.safely_drop_role('student');
SELECT public.safely_drop_role('ta');
DROP FUNCTION IF EXISTS public.safely_drop_role;



DROP EXTENSION IF EXISTS plpgsql;
DROP EXTENSION IF EXISTS pgcrypto;


COMMIT;
