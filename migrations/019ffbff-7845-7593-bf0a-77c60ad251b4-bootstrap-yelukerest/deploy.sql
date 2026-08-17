--
-- PostgreSQL database dump
--


-- Dumped from database version 18.4 (Debian 18.4-1.pgdg13+1)
-- Dumped by pg_dump version 18.4 (Debian 18.4-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: api; Type: SCHEMA; Schema: -; Owner: cluster_admin
--

CREATE SCHEMA api;

GRANT CREATE ON SCHEMA api TO api;


ALTER SCHEMA api OWNER TO yelukerest_migrator;

--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: cluster_admin
--

CREATE SCHEMA auth;


ALTER SCHEMA auth OWNER TO yelukerest_migrator;

--
-- Name: data; Type: SCHEMA; Schema: -; Owner: cluster_admin
--

CREATE SCHEMA data;


ALTER SCHEMA data OWNER TO yelukerest_migrator;

--
-- Name: pgjwt; Type: SCHEMA; Schema: -; Owner: cluster_admin
--

CREATE SCHEMA pgjwt;


ALTER SCHEMA pgjwt OWNER TO yelukerest_migrator;

--
-- Name: request; Type: SCHEMA; Schema: -; Owner: cluster_admin
--

CREATE SCHEMA request;


ALTER SCHEMA request OWNER TO yelukerest_migrator;

--
-- Name: settings; Type: SCHEMA; Schema: -; Owner: cluster_admin
--

CREATE SCHEMA settings;


ALTER SCHEMA settings OWNER TO yelukerest_migrator;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: user; Type: TYPE; Schema: api; Owner: cluster_admin
--

CREATE TYPE api."user" AS (
	id integer,
	netid text,
	email text,
	role text
);


ALTER TYPE api."user" OWNER TO yelukerest_migrator;

--
-- Name: meeting_type_enum; Type: TYPE; Schema: data; Owner: cluster_admin
--

CREATE TYPE data.meeting_type_enum AS ENUM (
    'lecture',
    'no-meeting',
    'office-hours'
);


ALTER TYPE data.meeting_type_enum OWNER TO yelukerest_migrator;

--
-- Name: participation_enum; Type: TYPE; Schema: data; Owner: cluster_admin
--

CREATE TYPE data.participation_enum AS ENUM (
    'absent',
    'attended',
    'contributed',
    'led'
);


ALTER TYPE data.participation_enum OWNER TO yelukerest_migrator;

--
-- Name: user_role; Type: TYPE; Schema: data; Owner: cluster_admin
--

CREATE TYPE data.user_role AS ENUM (
    'student',
    'faculty',
    'observer',
    'ta'
);


ALTER TYPE data.user_role OWNER TO yelukerest_migrator;

--
-- Name: check_request_jwt(); Type: FUNCTION; Schema: api; Owner: cluster_admin
--

CREATE FUNCTION api.check_request_jwt() RETURNS void
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'api', 'settings', 'request', 'pg_temp'
    AS $$
DECLARE
    claims jsonb;
    claim_role text;
    claim_issuer text;
    expected_audience text;
    expected_subject text;
    audience_claim jsonb;
    audience_text text;
    subject_claim text;
BEGIN
    claim_role := request.user_role();
    IF claim_role IS NULL OR claim_role = '' OR claim_role = 'anonymous' THEN
        RETURN;
    END IF;

    claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
    claim_issuer := request.jwt_claim('iss');
    IF claim_issuer IS DISTINCT FROM settings.get('jwt_issuer') THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt issuer';
    END IF;

    expected_audience := settings.get('jwt_audience');
    audience_claim := CASE WHEN claims IS NULL THEN NULL ELSE claims->'aud' END;
    audience_text := request.jwt_claim('aud');
    IF NOT (
        (jsonb_typeof(audience_claim) = 'string' AND audience_claim #>> '{}' = expected_audience)
        OR
        (jsonb_typeof(audience_claim) = 'array' AND audience_claim ? expected_audience)
        OR
        audience_text = expected_audience
    ) THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt audience';
    END IF;

    subject_claim := request.jwt_claim('sub');
    IF coalesce(subject_claim, '') = '' THEN
        RAISE insufficient_privilege USING MESSAGE = 'missing jwt subject';
    END IF;

    expected_subject := CASE
        WHEN claim_role = 'app' THEN 'app:' || coalesce(request.app_name(), '')
        ELSE 'user:' || coalesce(request.user_id_as_text(), '')
    END;
    IF subject_claim IS DISTINCT FROM expected_subject THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt subject';
    END IF;
END;
$$;


ALTER FUNCTION api.check_request_jwt() OWNER TO yelukerest_migrator;

--
-- Name: sign(json, text, text); Type: FUNCTION; Schema: pgjwt; Owner: cluster_admin
--

CREATE FUNCTION pgjwt.sign(payload json, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS text
    LANGUAGE sql
    AS $$
WITH
  header AS (
    SELECT pgjwt.url_encode(convert_to('{"alg":"' || algorithm || '","typ":"JWT"}', 'utf8'))
    ),
  payload AS (
    SELECT pgjwt.url_encode(convert_to(payload::text, 'utf8'))
    ),
  signables AS (
    SELECT (SELECT * FROM header) || '.' || (SELECT * FROM payload)
    )
SELECT
    (SELECT * FROM signables)
    || '.' ||
    pgjwt.algorithm_sign((SELECT * FROM signables), secret, algorithm);
$$;


ALTER FUNCTION pgjwt.sign(payload json, secret text, algorithm text) OWNER TO yelukerest_migrator;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: secrets; Type: TABLE; Schema: settings; Owner: cluster_admin
--

CREATE TABLE settings.secrets (
    key text NOT NULL,
    value text NOT NULL
);


ALTER TABLE settings.secrets OWNER TO yelukerest_migrator;

--
-- Name: get(text); Type: FUNCTION; Schema: settings; Owner: cluster_admin
--

CREATE FUNCTION settings.get(text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'settings', 'pg_temp'
    RETURN (SELECT secrets.value FROM settings.secrets WHERE (secrets.key = $1));


ALTER FUNCTION settings.get(text) OWNER TO yelukerest_migrator;

--
-- Name: sign_jwt(integer, data.user_role); Type: FUNCTION; Schema: auth; Owner: cluster_admin
--

CREATE FUNCTION auth.sign_jwt(user_id integer, role data.user_role) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'auth', 'settings', 'pgjwt', 'pg_temp'
    RETURN pgjwt.sign(json_build_object('iss', settings.get('jwt_issuer'::text), 'aud', settings.get('jwt_audience'::text), 'sub', ('user:'::text || (user_id)::text), 'user_id', user_id, 'role', (role)::text, 'iat', (EXTRACT(epoch FROM now()))::integer, 'nbf', (EXTRACT(epoch FROM now()))::integer, 'jti', (public.gen_random_uuid())::text, 'exp', ((EXTRACT(epoch FROM now()))::integer + (settings.get('jwt_lifetime'::text))::integer)), settings.get('jwt_secret'::text));


ALTER FUNCTION auth.sign_jwt(user_id integer, role data.user_role) OWNER TO yelukerest_migrator;

--
-- Name: jwt_claim(text); Type: FUNCTION; Schema: request; Owner: cluster_admin
--

CREATE FUNCTION request.jwt_claim(claim text) RETURNS text
    LANGUAGE sql STABLE
    RETURN COALESCE(NULLIF(current_setting(('request.jwt.claim.'::text || claim), true), ''::text), NULLIF(((NULLIF(current_setting('request.jwt.claims'::text, true), ''::text))::json ->> claim), ''::text));


ALTER FUNCTION request.jwt_claim(claim text) OWNER TO yelukerest_migrator;

--
-- Name: app_name(); Type: FUNCTION; Schema: request; Owner: cluster_admin
--

CREATE FUNCTION request.app_name() RETURNS text
    LANGUAGE sql STABLE
    RETURN request.jwt_claim('app_name'::text);


ALTER FUNCTION request.app_name() OWNER TO yelukerest_migrator;

--
-- Name: user_id_as_text(); Type: FUNCTION; Schema: request; Owner: cluster_admin
--

CREATE FUNCTION request.user_id_as_text() RETURNS text
    LANGUAGE sql STABLE
    RETURN request.jwt_claim('user_id'::text);


ALTER FUNCTION request.user_id_as_text() OWNER TO yelukerest_migrator;

--
-- Name: user_id(); Type: FUNCTION; Schema: request; Owner: cluster_admin
--

CREATE FUNCTION request.user_id() RETURNS integer
    LANGUAGE sql STABLE
    RETURN CASE request.user_id_as_text() WHEN ''::text THEN 0 ELSE (request.user_id_as_text())::integer END;


ALTER FUNCTION request.user_id() OWNER TO yelukerest_migrator;

--
-- Name: user_role(); Type: FUNCTION; Schema: request; Owner: cluster_admin
--

CREATE FUNCTION request.user_role() RETURNS text
    LANGUAGE sql STABLE
    RETURN request.jwt_claim('role'::text);


ALTER FUNCTION request.user_role() OWNER TO yelukerest_migrator;

--
-- Name: user; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data."user" (
    id integer NOT NULL,
    email text,
    netid text NOT NULL,
    name text,
    lastname text,
    organization text,
    known_as text,
    nickname text NOT NULL,
    role data.user_role DEFAULT (settings.get('auth.default-role'::text))::data.user_role NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    team_nickname text,
    CONSTRAINT user_check CHECK ((updated_at >= created_at)),
    CONSTRAINT user_email_check CHECK (((email ~ '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'::text) AND (char_length(email) < 100))),
    CONSTRAINT user_known_as_check CHECK ((char_length(known_as) < 50)),
    CONSTRAINT user_lastname_check CHECK ((char_length(lastname) < 100)),
    CONSTRAINT user_name_check CHECK ((char_length(name) < 100)),
    CONSTRAINT user_netid_check CHECK (((netid ~ '^[a-z]+[0-9]+$'::text) AND (char_length(netid) < 10))),
    CONSTRAINT user_nickname_check CHECK (((nickname ~ '^[\w]{2,20}-[\w]{2,20}$'::text) AND (char_length(nickname) < 50))),
    CONSTRAINT user_organization_check CHECK ((char_length(organization) < 200)),
    CONSTRAINT user_team_nickname_check CHECK ((char_length(team_nickname) < 50))
);


ALTER TABLE data."user" OWNER TO yelukerest_migrator;

--
-- Name: user_jwts; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.user_jwts AS
 SELECT
        CASE
            WHEN ((role <> 'observer'::data.user_role) AND ((request.user_role() = 'faculty'::text) OR (request.user_id() = id) OR ((request.user_role() = 'app'::text) AND (request.app_name() = 'authapp'::text)))) THEN auth.sign_jwt(id, role)
            ELSE NULL::text
        END AS jwt,
    id,
    email,
    netid,
    name,
    lastname,
    organization,
    known_as,
    nickname,
    role,
    created_at,
    updated_at,
    team_nickname
   FROM data."user";


ALTER VIEW api.user_jwts OWNER TO api;

--
-- Name: VIEW user_jwts; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.user_jwts IS 'JWT helper view for authenticated user and faculty flows';


--
-- Name: COLUMN user_jwts.jwt; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.jwt IS 'Signed JWT for the row user when the requester is allowed to receive it';


--
-- Name: COLUMN user_jwts.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.id IS 'Unique user id';


--
-- Name: COLUMN user_jwts.email; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.email IS 'User email address';


--
-- Name: COLUMN user_jwts.netid; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.netid IS 'University netid for the user';


--
-- Name: COLUMN user_jwts.name; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.name IS 'Given name for the user';


--
-- Name: COLUMN user_jwts.lastname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.lastname IS 'Family name for the user';


--
-- Name: COLUMN user_jwts.organization; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.organization IS 'Organization or school associated with the user';


--
-- Name: COLUMN user_jwts.known_as; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.known_as IS 'Preferred display name for the user';


--
-- Name: COLUMN user_jwts.nickname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.nickname IS 'Pseudonymous nickname used in class-facing displays';


--
-- Name: COLUMN user_jwts.role; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.role IS 'Course role assigned to the user';


--
-- Name: COLUMN user_jwts.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.created_at IS 'When this user row was created';


--
-- Name: COLUMN user_jwts.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.updated_at IS 'When this user row was last updated';


--
-- Name: COLUMN user_jwts.team_nickname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_jwts.team_nickname IS 'Team nickname assigned to the user, if any';


--
-- Name: issue_user_jwt(text); Type: FUNCTION; Schema: api; Owner: api
--

CREATE FUNCTION api.issue_user_jwt(requested_netid text) RETURNS SETOF api.user_jwts
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'api', 'request', 'pg_temp'
    BEGIN ATOMIC
 SELECT user_jwts.jwt,
     user_jwts.id,
     user_jwts.email,
     user_jwts.netid,
     user_jwts.name,
     user_jwts.lastname,
     user_jwts.organization,
     user_jwts.known_as,
     user_jwts.nickname,
     user_jwts.role,
     user_jwts.created_at,
     user_jwts.updated_at,
     user_jwts.team_nickname
    FROM api.user_jwts
   WHERE ((user_jwts.netid = issue_user_jwt.requested_netid) AND (request.user_role() = 'app'::text) AND (request.app_name() = 'authapp'::text));
END;


ALTER FUNCTION api.issue_user_jwt(requested_netid text) OWNER TO api;

--
-- Name: FUNCTION issue_user_jwt(requested_netid text); Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON FUNCTION api.issue_user_jwt(requested_netid text) IS 'Issue one user JWT for the requested netid when called by the authapp service';


--
-- Name: issue_user_jwt_for_mcp(text, text[], jsonb); Type: FUNCTION; Schema: api; Owner: cluster_admin
--

CREATE FUNCTION api.issue_user_jwt_for_mcp(p_netid text, p_scopes text[], p_external jsonb DEFAULT NULL::jsonb) RETURNS TABLE(jwt text, user_id integer, netid text, role text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'api', 'auth', 'data', 'request', 'settings', 'pg_temp'
    AS $_$
DECLARE
    target_user data."user"%ROWTYPE;
    allowed_roles text[];
    scopes_text text;
    token_jti text;
    signed_jwt text;
BEGIN
    -- Admit only the mcpapp service credential.
    IF NOT (request.user_role() = 'app' AND request.app_name() = 'mcpapp') THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'only the mcpapp service may mint MCP user JWTs';
    END IF;

    IF p_netid IS NULL OR p_netid = '' OR char_length(p_netid) >= 100 THEN
        RAISE EXCEPTION 'invalid netid' USING ERRCODE = '22023';
    END IF;

    -- Scopes are mandatory at mint time: consumers treat a missing or
    -- empty scopes claim as read-only at most (default-deny), but the
    -- mint path still insists on an explicit grant.
    IF p_scopes IS NULL OR cardinality(p_scopes) = 0 OR cardinality(p_scopes) > 16 THEN
        RAISE EXCEPTION 'between 1 and 16 scopes are required' USING ERRCODE = '22023';
    END IF;
    -- NULL elements must be rejected explicitly: `scope !~ pattern` is
    -- NULL (not true) for a NULL element, so a NULL would pass the
    -- pattern check and then be dropped silently by array_to_string,
    -- minting a token whose scopes differ from those requested.
    IF EXISTS (
        SELECT 1 FROM unnest(p_scopes) AS s(scope)
        WHERE s.scope IS NULL OR s.scope !~ '^[a-z][a-z0-9._:-]{0,63}$'
    ) THEN
        RAISE EXCEPTION 'malformed scope' USING ERRCODE = '22023';
    END IF;

    SELECT u.* INTO target_user
    FROM data."user" u
    WHERE u.netid = p_netid;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    allowed_roles := string_to_array(
        coalesce(settings.get('mcp_mintable_roles'), 'student,ta,faculty'),
        ','
    );
    IF NOT (target_user.role::text = ANY (allowed_roles)) THEN
        RAISE insufficient_privilege
            USING MESSAGE = format('users with role %s are not mintable for MCP', target_user.role);
    END IF;

    -- Disconnect has to mean something (issue #277). Revoking consent at
    -- Hydra kills the refresh token at once, but an access token already
    -- issued keeps verifying offline against the JWKS, so the only place left
    -- to stop it is here: mcpapp must come back for a fresh internal
    -- credential every few minutes, and this refuses to give it one.
    --
    -- The comparison is against the external token's issued-at, not simply
    -- "a revocation exists", so that reconnecting works. A token minted after
    -- the revocation comes from a new authorization the user just granted;
    -- one minted before it is the grant they cut off.
    --
    -- iat has one-second granularity, so a token issued in the same second as
    -- the revocation is ambiguous. It is treated as revoked (>=, not >),
    -- which errs toward refusing access rather than keeping it: the cost is
    -- that a reconnection completed inside the same second is refused and the
    -- user must click again, while the alternative would let a token issued
    -- at the moment of disconnect keep working for its full hour.
    --
    -- The five-second allowance is for clock skew between the authorization
    -- server and this database. iat comes from Hydra's clock; revoked_at from
    -- Postgres's. If Hydra runs ahead, a token issued BEFORE the disconnect
    -- can carry an iat after it and would otherwise look like a fresh grant,
    -- which is a bypass lasting until that token expires. Widening the
    -- comparison closes it, at the cost of refusing a reconnection finished
    -- within five seconds of the disconnect. Five is generous for hosts that
    -- share an NTP source and small enough that a person clicking through a
    -- consent screen never notices; deployments where the two clocks can
    -- drift further than that need to fix the clocks (see docs/hydra.md).
    IF p_external ? 'client_id' AND p_external->>'client_id' <> '' THEN
        IF EXISTS (
            SELECT 1
            FROM data.mcp_grant_revocation r
            WHERE r.user_id = target_user.id
              AND r.client_id = p_external->>'client_id'
              AND r.revoked_at >= coalesce(
                  to_timestamp((p_external->>'iat')::double precision)
                      - interval '5 seconds',
                  '-infinity'::timestamptz
              )
        ) THEN
            RAISE insufficient_privilege
                USING MESSAGE = 'this application was disconnected; reconnect it to continue';
        END IF;
    END IF;

    token_jti := public.gen_random_uuid()::text;
    scopes_text := array_to_string(p_scopes, ' ');
    signed_jwt := auth.sign_mcp_user_jwt(
        target_user.id,
        target_user.role,
        target_user.netid,
        scopes_text,
        token_jti
    );

    -- Same-transaction audit: if this insert fails, no token escapes.
    INSERT INTO data.mcp_jwt_mint_event (
        user_id,
        netid,
        user_role,
        scopes,
        jti,
        caller_app_name,
        external_issuer,
        external_sub,
        external_jti,
        external_client_id
    )
    VALUES (
        target_user.id,
        target_user.netid,
        target_user.role::text,
        scopes_text,
        token_jti,
        request.app_name(),
        p_external->>'iss',
        p_external->>'sub',
        p_external->>'jti',
        p_external->>'client_id'
    );

    RETURN QUERY SELECT signed_jwt, target_user.id, target_user.netid, target_user.role::text;
END;
$_$;


ALTER FUNCTION api.issue_user_jwt_for_mcp(p_netid text, p_scopes text[], p_external jsonb) OWNER TO yelukerest_migrator;

--
-- Name: FUNCTION issue_user_jwt_for_mcp(p_netid text, p_scopes text[], p_external jsonb); Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON FUNCTION api.issue_user_jwt_for_mcp(p_netid text, p_scopes text[], p_external jsonb) IS 'Mint a short-lived scope-carrying internal user JWT for the mcpapp service, auditing every mint';


--
-- Name: record_mcp_grant_revocation(text, text, text, text); Type: FUNCTION; Schema: api; Owner: cluster_admin
--

CREATE FUNCTION api.record_mcp_grant_revocation(netid text, client_id text, client_name text DEFAULT NULL::text, scopes text DEFAULT NULL::text) RETURNS TABLE(revoked_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'api', 'auth', 'data', 'request', 'settings', 'pg_temp'
    AS $$
DECLARE
    target_user data."user"%ROWTYPE;
    recorded timestamptz;
BEGIN
    IF NOT (request.user_role() = 'app' AND request.app_name() = 'authapp') THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'only the authapp service may record a grant revocation';
    END IF;

    IF client_id IS NULL OR client_id = '' OR char_length(client_id) > 500 THEN
        RAISE EXCEPTION 'a client_id is required' USING ERRCODE = '22023';
    END IF;

    SELECT u.* INTO target_user FROM data."user" u WHERE u.netid = record_mcp_grant_revocation.netid;
    IF NOT FOUND THEN
        -- Same posture as the mint path: an unknown netid is an empty result,
        -- not an error that would confirm which netids exist.
        RETURN;
    END IF;

    INSERT INTO data.mcp_grant_revocation (user_id, netid, client_id, client_name, scopes)
    VALUES (
        target_user.id,
        target_user.netid,
        record_mcp_grant_revocation.client_id,
        left(record_mcp_grant_revocation.client_name, 500),
        left(record_mcp_grant_revocation.scopes, 1024)
    )
    RETURNING mcp_grant_revocation.revoked_at INTO recorded;

    RETURN QUERY SELECT recorded;
END;
$$;


ALTER FUNCTION api.record_mcp_grant_revocation(netid text, client_id text, client_name text, scopes text) OWNER TO yelukerest_migrator;

--
-- Name: sync_assignments(jsonb, boolean, boolean); Type: FUNCTION; Schema: api; Owner: cluster_admin
--

CREATE FUNCTION api.sync_assignments(p_assignments jsonb, p_delete_missing boolean DEFAULT false, p_dry_run boolean DEFAULT false) RETURNS TABLE(inserted_count integer, updated_count integer, unchanged_count integer, deleted_count integer, field_inserted_count integer, field_updated_count integer, field_unchanged_count integer, field_deleted_count integer, dry_run boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
    input_count integer;
    duplicate_assignment_slug text;
    invalid_assignment_field_slug text;
    oversized_fields_assignment_slug text;
    duplicate_field_key text;
BEGIN
    p_delete_missing := COALESCE(p_delete_missing, false);
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;

    IF p_assignments IS NULL OR jsonb_typeof(p_assignments) <> 'array' THEN
        RAISE EXCEPTION 'sync_assignments expects a JSON array'
            USING ERRCODE = '22023';
    END IF;

    IF octet_length(p_assignments::text) > 8388608 THEN
        RAISE EXCEPTION 'sync_assignments payload exceeds the 8 MB limit'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_assignments);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'sync_assignments refuses to sync an empty assignment list'
            USING ERRCODE = '22023';
    END IF;

    IF input_count > 500 THEN
        RAISE EXCEPTION 'sync_assignments accepts at most 500 assignments, received %', input_count
            USING ERRCODE = '22023';
    END IF;

    SELECT assignment.slug INTO duplicate_assignment_slug
    FROM jsonb_to_recordset(p_assignments) AS assignment (
        slug text
    )
    GROUP BY assignment.slug
    HAVING count(*) > 1
    LIMIT 1;

    IF duplicate_assignment_slug IS NOT NULL THEN
        RAISE EXCEPTION 'sync_assignments received duplicate assignment slug: %', duplicate_assignment_slug
            USING ERRCODE = '23505';
    END IF;

    SELECT COALESCE(assignment.value->>'slug', '<missing slug>') INTO invalid_assignment_field_slug
    FROM jsonb_array_elements(p_assignments) AS assignment(value)
    WHERE NOT (assignment.value ? 'fields')
        OR jsonb_typeof(assignment.value->'fields') <> 'array'
    LIMIT 1;

    IF invalid_assignment_field_slug IS NOT NULL THEN
        RAISE EXCEPTION 'sync_assignments expected fields to be an array for assignment: %', invalid_assignment_field_slug
            USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(assignment.value->>'slug', '<missing slug>') INTO oversized_fields_assignment_slug
    FROM jsonb_array_elements(p_assignments) AS assignment(value)
    WHERE jsonb_array_length(assignment.value->'fields') > 50
    LIMIT 1;

    IF oversized_fields_assignment_slug IS NOT NULL THEN
        RAISE EXCEPTION 'sync_assignments accepts at most 50 fields per assignment, exceeded for assignment: %', oversized_fields_assignment_slug
            USING ERRCODE = '22023';
    END IF;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.slug
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text
        )
    )
    SELECT input_fields.assignment_slug || '/' || input_fields.slug INTO duplicate_field_key
    FROM input_fields
    GROUP BY input_fields.assignment_slug, input_fields.slug
    HAVING count(*) > 1
    LIMIT 1;

    IF duplicate_field_key IS NOT NULL THEN
        RAISE EXCEPTION 'sync_assignments received duplicate assignment field key: %', duplicate_field_key
            USING ERRCODE = '23505';
    END IF;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text
        )
    )
    SELECT count(*)::integer INTO inserted_count
    FROM input_assignments input_assignment
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.assignments existing_assignment
        WHERE existing_assignment.slug = input_assignment.slug
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            points_possible smallint,
            is_draft boolean,
            is_markdown boolean,
            is_team boolean,
            title text,
            body text,
            closed_at timestamptz
        )
    )
    SELECT count(*)::integer INTO updated_count
    FROM input_assignments input_assignment
    JOIN api.assignments existing_assignment
        ON existing_assignment.slug = input_assignment.slug
    WHERE (
        existing_assignment.points_possible,
        existing_assignment.is_draft,
        existing_assignment.is_markdown,
        existing_assignment.is_team,
        existing_assignment.title,
        existing_assignment.body,
        existing_assignment.closed_at
    ) IS DISTINCT FROM (
        input_assignment.points_possible,
        COALESCE(input_assignment.is_draft, existing_assignment.is_draft),
        COALESCE(input_assignment.is_markdown, existing_assignment.is_markdown),
        COALESCE(input_assignment.is_team, existing_assignment.is_team),
        input_assignment.title,
        input_assignment.body,
        input_assignment.closed_at
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            points_possible smallint,
            is_draft boolean,
            is_markdown boolean,
            is_team boolean,
            title text,
            body text,
            closed_at timestamptz
        )
    )
    SELECT count(*)::integer INTO unchanged_count
    FROM input_assignments input_assignment
    JOIN api.assignments existing_assignment
        ON existing_assignment.slug = input_assignment.slug
    WHERE NOT (
        (
            existing_assignment.points_possible,
            existing_assignment.is_draft,
            existing_assignment.is_markdown,
            existing_assignment.is_team,
            existing_assignment.title,
            existing_assignment.body,
            existing_assignment.closed_at
        ) IS DISTINCT FROM (
            input_assignment.points_possible,
            COALESCE(input_assignment.is_draft, existing_assignment.is_draft),
            COALESCE(input_assignment.is_markdown, existing_assignment.is_markdown),
            COALESCE(input_assignment.is_team, existing_assignment.is_team),
            input_assignment.title,
            input_assignment.body,
            input_assignment.closed_at
        )
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text
        )
    )
    SELECT
        CASE
            WHEN p_delete_missing THEN count(*)::integer
            ELSE 0
        END
        INTO deleted_count
    FROM api.assignments existing_assignment
    WHERE NOT EXISTS (
        SELECT 1
        FROM input_assignments input_assignment
        WHERE input_assignment.slug = existing_assignment.slug
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.slug
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text
        )
    )
    SELECT count(*)::integer INTO field_inserted_count
    FROM input_fields input_field
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.assignment_fields existing_field
        WHERE existing_field.assignment_slug = input_field.assignment_slug
            AND existing_field.slug = input_field.slug
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    )
    SELECT count(*)::integer INTO field_updated_count
    FROM input_fields input_field
    JOIN api.assignment_fields existing_field
        ON existing_field.assignment_slug = input_field.assignment_slug
        AND existing_field.slug = input_field.slug
    WHERE (
        existing_field.label,
        existing_field.help,
        existing_field.placeholder,
        existing_field.is_url,
        existing_field.is_multiline,
        existing_field.display_order,
        existing_field.pattern,
        existing_field.example
    ) IS DISTINCT FROM (
        input_field.label,
        input_field.help,
        input_field.placeholder,
        COALESCE(input_field.is_url, existing_field.is_url),
        COALESCE(input_field.is_multiline, existing_field.is_multiline),
        COALESCE(input_field.display_order, existing_field.display_order),
        COALESCE(input_field.pattern, existing_field.pattern),
        COALESCE(input_field.example, existing_field.example)
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    )
    SELECT count(*)::integer INTO field_unchanged_count
    FROM input_fields input_field
    JOIN api.assignment_fields existing_field
        ON existing_field.assignment_slug = input_field.assignment_slug
        AND existing_field.slug = input_field.slug
    WHERE NOT (
        (
            existing_field.label,
            existing_field.help,
            existing_field.placeholder,
            existing_field.is_url,
            existing_field.is_multiline,
            existing_field.display_order,
            existing_field.pattern,
            existing_field.example
        ) IS DISTINCT FROM (
            input_field.label,
            input_field.help,
            input_field.placeholder,
            COALESCE(input_field.is_url, existing_field.is_url),
            COALESCE(input_field.is_multiline, existing_field.is_multiline),
            COALESCE(input_field.display_order, existing_field.display_order),
            COALESCE(input_field.pattern, existing_field.pattern),
            COALESCE(input_field.example, existing_field.example)
        )
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.slug
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text
        )
    )
    SELECT count(*)::integer INTO field_deleted_count
    FROM api.assignment_fields existing_field
    WHERE (
            p_delete_missing
            OR EXISTS (
                SELECT 1
                FROM input_assignments input_assignment
                WHERE input_assignment.slug = existing_field.assignment_slug
            )
        )
        AND NOT EXISTS (
            SELECT 1
            FROM input_fields input_field
            WHERE input_field.assignment_slug = existing_field.assignment_slug
                AND input_field.slug = existing_field.slug
        );

    IF p_dry_run THEN
        RETURN NEXT;
        RETURN;
    END IF;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    ),
    deleted_fields AS (
        DELETE FROM api.assignment_fields existing_field
        WHERE (
                p_delete_missing
                OR EXISTS (
                    SELECT 1
                    FROM input_assignments input_assignment
                    WHERE input_assignment.slug = existing_field.assignment_slug
                )
            )
            AND NOT EXISTS (
                SELECT 1
                FROM input_fields input_field
                WHERE input_field.assignment_slug = existing_field.assignment_slug
                    AND input_field.slug = existing_field.slug
            )
        RETURNING existing_field.slug, existing_field.assignment_slug
    )
    SELECT count(*)::integer INTO field_deleted_count
    FROM deleted_fields;

    IF p_delete_missing THEN
        WITH input_assignments AS (
            SELECT *
            FROM jsonb_to_recordset(p_assignments) AS assignment (
                slug text
            )
        ),
        deleted_assignments AS (
            DELETE FROM api.assignments existing_assignment
            WHERE NOT EXISTS (
                SELECT 1
                FROM input_assignments input_assignment
                WHERE input_assignment.slug = existing_assignment.slug
            )
            RETURNING existing_assignment.slug
        )
        SELECT count(*)::integer INTO deleted_count
        FROM deleted_assignments;
    ELSE
        deleted_count := 0;
    END IF;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            points_possible smallint,
            is_draft boolean,
            is_markdown boolean,
            is_team boolean,
            title text,
            body text,
            closed_at timestamptz
        )
    ),
    updated_assignments AS (
        UPDATE api.assignments existing_assignment
        SET
            points_possible = input_assignment.points_possible,
            is_draft = COALESCE(input_assignment.is_draft, existing_assignment.is_draft),
            is_markdown = COALESCE(input_assignment.is_markdown, existing_assignment.is_markdown),
            is_team = COALESCE(input_assignment.is_team, existing_assignment.is_team),
            title = input_assignment.title,
            body = input_assignment.body,
            closed_at = input_assignment.closed_at
        FROM input_assignments input_assignment
        WHERE existing_assignment.slug = input_assignment.slug
            AND (
                existing_assignment.points_possible,
                existing_assignment.is_draft,
                existing_assignment.is_markdown,
                existing_assignment.is_team,
                existing_assignment.title,
                existing_assignment.body,
                existing_assignment.closed_at
            ) IS DISTINCT FROM (
                input_assignment.points_possible,
                COALESCE(input_assignment.is_draft, existing_assignment.is_draft),
                COALESCE(input_assignment.is_markdown, existing_assignment.is_markdown),
                COALESCE(input_assignment.is_team, existing_assignment.is_team),
                input_assignment.title,
                input_assignment.body,
                input_assignment.closed_at
            )
        RETURNING existing_assignment.slug
    )
    SELECT count(*)::integer INTO updated_count
    FROM updated_assignments;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            points_possible smallint,
            is_draft boolean,
            is_markdown boolean,
            is_team boolean,
            title text,
            body text,
            closed_at timestamptz
        )
    ),
    inserted_assignments AS (
        INSERT INTO api.assignments (
            slug,
            points_possible,
            is_draft,
            is_markdown,
            is_team,
            title,
            body,
            closed_at
        )
        SELECT
            input_assignment.slug,
            input_assignment.points_possible,
            COALESCE(input_assignment.is_draft, true),
            COALESCE(input_assignment.is_markdown, false),
            COALESCE(input_assignment.is_team, false),
            input_assignment.title,
            input_assignment.body,
            input_assignment.closed_at
        FROM input_assignments input_assignment
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.assignments existing_assignment
            WHERE existing_assignment.slug = input_assignment.slug
        )
        RETURNING slug
    )
    SELECT count(*)::integer INTO inserted_count
    FROM inserted_assignments;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    ),
    updated_fields AS (
        UPDATE api.assignment_fields existing_field
        SET
            label = input_field.label,
            help = input_field.help,
            placeholder = input_field.placeholder,
            is_url = COALESCE(input_field.is_url, existing_field.is_url),
            is_multiline = COALESCE(input_field.is_multiline, existing_field.is_multiline),
            display_order = COALESCE(input_field.display_order, existing_field.display_order),
            pattern = COALESCE(input_field.pattern, existing_field.pattern),
            example = COALESCE(input_field.example, existing_field.example)
        FROM input_fields input_field
        WHERE existing_field.assignment_slug = input_field.assignment_slug
            AND existing_field.slug = input_field.slug
            AND (
                existing_field.label,
                existing_field.help,
                existing_field.placeholder,
                existing_field.is_url,
                existing_field.is_multiline,
                existing_field.display_order,
                existing_field.pattern,
                existing_field.example
            ) IS DISTINCT FROM (
                input_field.label,
                input_field.help,
                input_field.placeholder,
                COALESCE(input_field.is_url, existing_field.is_url),
                COALESCE(input_field.is_multiline, existing_field.is_multiline),
                COALESCE(input_field.display_order, existing_field.display_order),
                COALESCE(input_field.pattern, existing_field.pattern),
                COALESCE(input_field.example, existing_field.example)
            )
        RETURNING existing_field.slug, existing_field.assignment_slug
    )
    SELECT count(*)::integer INTO field_updated_count
    FROM updated_fields;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    ),
    inserted_fields AS (
        INSERT INTO api.assignment_fields (
            slug,
            assignment_slug,
            label,
            help,
            placeholder,
            is_url,
            is_multiline,
            display_order,
            pattern,
            example
        )
        SELECT
            input_field.slug,
            input_field.assignment_slug,
            input_field.label,
            input_field.help,
            input_field.placeholder,
            COALESCE(input_field.is_url, false),
            COALESCE(input_field.is_multiline, false),
            COALESCE(input_field.display_order, 0),
            COALESCE(input_field.pattern, '.*'),
            COALESCE(input_field.example, '')
        FROM input_fields input_field
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.assignment_fields existing_field
            WHERE existing_field.assignment_slug = input_field.assignment_slug
                AND existing_field.slug = input_field.slug
        )
        RETURNING slug, assignment_slug
    )
    SELECT count(*)::integer INTO field_inserted_count
    FROM inserted_fields;

    RETURN NEXT;
END;
$$;


ALTER FUNCTION api.sync_assignments(p_assignments jsonb, p_delete_missing boolean, p_dry_run boolean) OWNER TO yelukerest_migrator;

--
-- Name: sync_meetings(jsonb); Type: FUNCTION; Schema: api; Owner: cluster_admin
--

CREATE FUNCTION api.sync_meetings(p_meetings jsonb) RETURNS TABLE(inserted_count integer, updated_count integer, unchanged_count integer, deleted_count integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    input_count integer;
    duplicate_slug text;
BEGIN
    IF p_meetings IS NULL OR jsonb_typeof(p_meetings) <> 'array' THEN
        RAISE EXCEPTION 'sync_meetings expects a JSON array'
            USING ERRCODE = '22023';
    END IF;

    IF octet_length(p_meetings::text) > 4194304 THEN
        RAISE EXCEPTION 'sync_meetings payload exceeds the 4 MB limit'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_meetings);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'sync_meetings refuses to sync an empty meeting list'
            USING ERRCODE = '22023';
    END IF;

    IF input_count > 500 THEN
        RAISE EXCEPTION 'sync_meetings accepts at most 500 meetings, received %', input_count
            USING ERRCODE = '22023';
    END IF;

    SELECT meeting.slug INTO duplicate_slug
    FROM jsonb_to_recordset(p_meetings) AS meeting (
        slug text,
        title text,
        summary text,
        description text,
        begins_at timestamptz,
        duration interval,
        meeting_type data.meeting_type_enum,
        is_draft boolean
    )
    GROUP BY meeting.slug
    HAVING count(*) > 1
    LIMIT 1;

    IF duplicate_slug IS NOT NULL THEN
        RAISE EXCEPTION 'sync_meetings received duplicate meeting slug: %', duplicate_slug
            USING ERRCODE = '23505';
    END IF;

    WITH input_meetings AS (
        SELECT *
        FROM jsonb_to_recordset(p_meetings) AS meeting (
            slug text,
            title text,
            summary text,
            description text,
            begins_at timestamptz,
            duration interval,
            meeting_type data.meeting_type_enum,
            is_draft boolean
        )
    ),
    deleted_meetings AS (
        DELETE FROM api.meetings existing_meeting
        WHERE NOT EXISTS (
            SELECT 1
            FROM input_meetings input_meeting
            WHERE input_meeting.slug = existing_meeting.slug
        )
        RETURNING existing_meeting.slug
    )
    SELECT count(*)::integer INTO deleted_count
    FROM deleted_meetings;

    WITH input_meetings AS (
        SELECT *
        FROM jsonb_to_recordset(p_meetings) AS meeting (
            slug text,
            title text,
            summary text,
            description text,
            begins_at timestamptz,
            duration interval,
            meeting_type data.meeting_type_enum,
            is_draft boolean
        )
    )
    SELECT count(*)::integer INTO unchanged_count
    FROM input_meetings input_meeting
    JOIN api.meetings existing_meeting
        ON existing_meeting.slug = input_meeting.slug
    WHERE NOT (
        (
            existing_meeting.title,
            existing_meeting.summary,
            existing_meeting.description,
            existing_meeting.begins_at,
            existing_meeting.duration,
            existing_meeting.meeting_type,
            existing_meeting.is_draft
        ) IS DISTINCT FROM (
            input_meeting.title,
            input_meeting.summary,
            input_meeting.description,
            input_meeting.begins_at,
            input_meeting.duration,
            COALESCE(input_meeting.meeting_type, 'lecture'::data.meeting_type_enum),
            input_meeting.is_draft
        )
    );

    WITH input_meetings AS (
        SELECT *
        FROM jsonb_to_recordset(p_meetings) AS meeting (
            slug text,
            title text,
            summary text,
            description text,
            begins_at timestamptz,
            duration interval,
            meeting_type data.meeting_type_enum,
            is_draft boolean
        )
    ),
    changed_meetings AS (
        SELECT input_meeting.*
        FROM input_meetings input_meeting
        JOIN api.meetings existing_meeting
            ON existing_meeting.slug = input_meeting.slug
        WHERE (
            existing_meeting.title,
            existing_meeting.summary,
            existing_meeting.description,
            existing_meeting.begins_at,
            existing_meeting.duration,
            existing_meeting.meeting_type,
            existing_meeting.is_draft
        ) IS DISTINCT FROM (
            input_meeting.title,
            input_meeting.summary,
            input_meeting.description,
            input_meeting.begins_at,
            input_meeting.duration,
            COALESCE(input_meeting.meeting_type, 'lecture'::data.meeting_type_enum),
            input_meeting.is_draft
        )
    ),
    updated_meetings AS (
        UPDATE api.meetings existing_meeting
        SET
            title = input_meeting.title,
            summary = input_meeting.summary,
            description = input_meeting.description,
            begins_at = input_meeting.begins_at,
            duration = input_meeting.duration,
            meeting_type = COALESCE(input_meeting.meeting_type, 'lecture'::data.meeting_type_enum),
            is_draft = input_meeting.is_draft
        FROM changed_meetings input_meeting
        WHERE existing_meeting.slug = input_meeting.slug
        RETURNING existing_meeting.slug
    )
    SELECT count(*)::integer INTO updated_count
    FROM updated_meetings;

    WITH input_meetings AS (
        SELECT *
        FROM jsonb_to_recordset(p_meetings) AS meeting (
            slug text,
            title text,
            summary text,
            description text,
            begins_at timestamptz,
            duration interval,
            meeting_type data.meeting_type_enum,
            is_draft boolean
        )
    ),
    inserted_meetings AS (
        INSERT INTO api.meetings (
            slug,
            title,
            summary,
            description,
            begins_at,
            duration,
            meeting_type,
            is_draft
        )
        SELECT
            input_meeting.slug,
            input_meeting.title,
            input_meeting.summary,
            input_meeting.description,
            input_meeting.begins_at,
            input_meeting.duration,
            COALESCE(input_meeting.meeting_type, 'lecture'::data.meeting_type_enum),
            input_meeting.is_draft
        FROM input_meetings input_meeting
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.meetings existing_meeting
            WHERE existing_meeting.slug = input_meeting.slug
        )
        RETURNING slug
    )
    SELECT count(*)::integer INTO inserted_count
    FROM inserted_meetings;

    RETURN NEXT;
END;
$$;


ALTER FUNCTION api.sync_meetings(p_meetings jsonb) OWNER TO yelukerest_migrator;

--
-- Name: sign_mcp_user_jwt(integer, data.user_role, text, text, text); Type: FUNCTION; Schema: auth; Owner: cluster_admin
--

CREATE FUNCTION auth.sign_mcp_user_jwt(user_id integer, role data.user_role, netid text, scopes text, jti text) RETURNS text
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'auth', 'settings', 'pgjwt', 'pg_temp'
    RETURN pgjwt.sign(json_build_object('iss', settings.get('jwt_issuer'::text), 'aud', json_build_array(settings.get('jwt_audience'::text), COALESCE(settings.get('jwt_mcp_audience'::text), 'yelukerest-mcp'::text)), 'sub', ('user:'::text || (user_id)::text), 'user_id', user_id, 'role', (role)::text, 'netid', netid, 'scopes', scopes, 'iat', (EXTRACT(epoch FROM now()))::integer, 'nbf', (EXTRACT(epoch FROM now()))::integer, 'jti', jti, 'exp', ((EXTRACT(epoch FROM now()))::integer + 600)), settings.get('jwt_secret'::text));


ALTER FUNCTION auth.sign_mcp_user_jwt(user_id integer, role data.user_role, netid text, scopes text, jti text) OWNER TO yelukerest_migrator;

--
-- Name: assignment_field_submission_is_writable_by_current_user(integer); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.assignment_field_submission_is_writable_by_current_user(the_assignment_submission_id integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT ass_sub.id
        FROM data.assignment_submission AS ass_sub
        INNER JOIN data."user" AS u
        ON (
            ass_sub.user_id = u.id
            OR
            ass_sub.team_nickname = u.team_nickname
        )
        INNER JOIN data.assignment AS a
        ON a.slug = ass_sub.assignment_slug
        LEFT JOIN data.assignment_grade_exception AS ge
        ON (
            ge.assignment_slug = ass_sub.assignment_slug
            AND
            (
                (ass_sub.is_team AND ge.team_nickname = ass_sub.team_nickname)
                OR
                (NOT ass_sub.is_team AND ge.user_id = ass_sub.user_id)
            )
        )
        WHERE
            u.id = request.user_id()
            AND ass_sub.id = the_assignment_submission_id
            AND (
                (
                    a.is_draft = false
                    AND current_timestamp < a.closed_at
                )
                OR
                (
                    ge.closed_at > current_timestamp
                    AND (
                        ge.user_id = ass_sub.user_id
                        OR
                        ge.team_nickname = ass_sub.team_nickname
                    )
                )
            )
    );
END;
$$;


ALTER FUNCTION data.assignment_field_submission_is_writable_by_current_user(the_assignment_submission_id integer) OWNER TO yelukerest_migrator;

--
-- Name: clean_user_fields(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.clean_user_fields() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.email := lower(NEW.email);
    NEW.netid := lower(NEW.netid);
    NEW.nickname := lower(NEW.nickname);
    NEW.updated_at = current_timestamp;
    return NEW;
END;
$$;


ALTER FUNCTION data.clean_user_fields() OWNER TO yelukerest_migrator;

--
-- Name: ensure_student_engagement_rows(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.ensure_student_engagement_rows() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    IF (
        NEW.role = 'student'::user_role
        AND (TG_OP = 'INSERT' OR OLD.role IS DISTINCT FROM NEW.role)
    ) THEN
        INSERT INTO data.engagement (user_id, meeting_slug, participation)
        SELECT NEW.id, meeting.slug, 'absent'::participation_enum
        FROM data.meeting AS meeting
        ON CONFLICT (user_id, meeting_slug) DO NOTHING;
    END IF;

    RETURN NULL;
END;
$$;


ALTER FUNCTION data.ensure_student_engagement_rows() OWNER TO yelukerest_migrator;

--
-- Name: fill_assignment_field_submission_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.fill_assignment_field_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Fill in the assignment_slug if it is NULL by looking
    -- at the assignment_slug from the assignment_submission.
    IF (NEW.assignment_slug IS NULL AND NEW.assignment_submission_id IS NOT NULL) THEN
        SELECT assignment_slug INTO NEW.assignment_slug
        FROM data.assignment_submission
        WHERE id = NEW.assignment_submission_id;
    END IF;
    -- Fill in the assignment_submission_id if it is null
    -- by looking at the assignment if the assignment_slug
    -- is not null.
    IF (NEW.assignment_submission_id IS NULL and NEW.assignment_slug IS NOT NULL and request.user_id() IS NOT NULL) THEN
        SELECT ass.id INTO NEW.assignment_submission_id
        FROM
            (data.assignment_submission ass
            LEFT OUTER JOIN data."user" u
            ON u.team_nickname = ass.team_nickname)
        WHERE (
            -- It is the right assignment
            assignment_slug = NEW.assignment_slug
            AND
            -- It is theirs or their teams assignment submission
            (u.id = request.user_id() OR user_id = request.user_id())
        );
    END IF;

    -- Try to fill in the `submitter_user_id`
    IF (request.user_id() IS NULL ) THEN
        IF (NEW.submitter_user_id IS NULL ) THEN
            -- In practice this should only be the case when an
            -- administrator is using the database directly and
            -- not through the API.
            SELECT submitter_user_id INTO NEW.submitter_user_id
            FROM data.assignment_submission AS sub
            WHERE sub.id = NEW.assignment_submission_id;
        END IF;
    ELSE
        NEW.submitter_user_id = request.user_id();
    END IF;

    -- Try to fill in `pattern`
    IF (NEW.assignment_field_pattern is NULL) THEN
        SELECT pattern INTO NEW.assignment_field_pattern
        FROM data.assignment_field AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    -- Try to fill in `is_url`
    IF (NEW.assignment_field_is_url is NULL) THEN
        SELECT is_url INTO NEW.assignment_field_is_url
        FROM data.assignment_field AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    IF (TG_OP = 'UPDATE') THEN
        -- Optimistic concurrency: clients may include the `updated_at`
        -- they last read in an UPDATE. If it does not match the current
        -- row we reject the write as stale. Clients that omit
        -- `updated_at` skip this check (PostgREST leaves the old value
        -- in place for columns absent from the payload).
        IF (NEW.updated_at IS DISTINCT FROM OLD.updated_at) THEN
            RAISE EXCEPTION 'stale write rejected: submission last updated at %, client expected %', OLD.updated_at, NEW.updated_at
                USING ERRCODE = 'PT409',
                      DETAIL = 'The assignment field submission changed since it was last read.',
                      HINT = 'Re-fetch the submission and retry with its current updated_at.';
        END IF;
        -- `created_at` is immutable once the row exists.
        NEW.created_at = OLD.created_at;
    ELSE
        -- Prevent API clients from supplying a bogus `created_at`.
        -- Direct database loads (no request user) keep their values.
        IF (request.user_id() IS NOT NULL) THEN
            NEW.created_at = current_timestamp;
        ELSE
            NEW.created_at = COALESCE(NEW.created_at, current_timestamp);
        END IF;
    END IF;

    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_field_submission_defaults() OWNER TO yelukerest_migrator;

--
-- Name: fill_assignment_grade_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.fill_assignment_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT ass_sub.assignment_slug INTO NEW.assignment_slug
        FROM data.assignment_submission AS ass_sub
        WHERE ass_sub.id = NEW.assignment_submission_id;
    END IF;
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM data.assignment
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_grade_defaults() OWNER TO yelukerest_migrator;

--
-- Name: fill_assignment_grade_exception_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.fill_assignment_grade_exception_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM data.assignment
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_grade_exception_defaults() OWNER TO yelukerest_migrator;

--
-- Name: fill_assignment_submission_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.fill_assignment_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM data.assignment
        WHERE slug = NEW.assignment_slug;
    END IF;
    -- Set default user_id from request credentials
    IF (NEW.user_id IS NULL AND NOT NEW.is_team ) THEN
        NEW.user_id = request.user_id();
    END IF;
    -- Set default submitter_user_id. This is done in 
    -- the table defaults, but we do it here so that
    -- we can fill in team nickname below.
    IF (NEW.submitter_user_id IS NULL ) THEN
        IF (request.user_id() IS NULL ) THEN
            IF (NEW.user_id IS NOT NULL) THEN
                NEW.submitter_user_id = NEW.user_id;
            END IF;
        ELSE
            NEW.submitter_user_id = request.user_id();
        END IF;
    END IF;
    -- Set default team_nickname from user table
    IF (NEW.is_team AND NEW.team_nickname IS NULL) THEN
        SELECT u.team_nickname INTO NEW.team_nickname
        FROM data."user" AS u
        WHERE u.id = NEW.submitter_user_id;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_submission_defaults() OWNER TO yelukerest_migrator;

--
-- Name: fill_grade_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.fill_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_grade_defaults() OWNER TO yelukerest_migrator;

--
-- Name: fill_grade_snapshot_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.fill_grade_snapshot_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_grade_snapshot_defaults() OWNER TO yelukerest_migrator;

--
-- Name: fill_quiz_grade_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.fill_quiz_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM data.quiz
        WHERE id = NEW.quiz_id;
    END IF;
    IF (NEW.user_id IS NULL and request.user_id() IS NOT NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_quiz_grade_defaults() OWNER TO yelukerest_migrator;

--
-- Name: fill_quiz_submission_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.fill_quiz_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.user_id IS NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_quiz_submission_defaults() OWNER TO yelukerest_migrator;

--
-- Name: fill_user_secret_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.fill_user_secret_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_user_secret_defaults() OWNER TO yelukerest_migrator;

--
-- Name: mcp_grant_revocation_is_append_only(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.mcp_grant_revocation_is_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'mcp_grant_revocation is append-only'
        USING ERRCODE = '42501';
END;
$$;


ALTER FUNCTION data.mcp_grant_revocation_is_append_only() OWNER TO yelukerest_migrator;

--
-- Name: prevent_assignment_field_submission_event_mutation(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.prevent_assignment_field_submission_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'assignment field submission event history is append-only';
END;
$$;


ALTER FUNCTION data.prevent_assignment_field_submission_event_mutation() OWNER TO yelukerest_migrator;

--
-- Name: prevent_grade_event_mutation(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.prevent_grade_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'grade event history is append-only';
END;
$$;


ALTER FUNCTION data.prevent_grade_event_mutation() OWNER TO yelukerest_migrator;

--
-- Name: prevent_mcp_jwt_mint_event_mutation(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.prevent_mcp_jwt_mint_event_mutation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'mcp jwt mint event history is append-only';
END;
$$;


ALTER FUNCTION data.prevent_mcp_jwt_mint_event_mutation() OWNER TO yelukerest_migrator;

--
-- Name: quiz_set_defaults(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.quiz_set_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
  IF (NEW.closed_at IS NULL) THEN
    SELECT begins_at INTO NEW.closed_at
    FROM data.meeting
    WHERE slug = NEW.meeting_slug;
  END IF;
  IF (NEW.open_at IS NULL) THEN
    SELECT (begins_at - '5 days'::INTERVAL) INTO NEW.open_at
    FROM data.meeting
    WHERE slug = NEW.meeting_slug;
  END IF;
  NEW.updated_at = current_timestamp;
  RETURN NEW;
END; $$;


ALTER FUNCTION data.quiz_set_defaults() OWNER TO yelukerest_migrator;

--
-- Name: record_assignment_field_submission_event(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.record_assignment_field_submission_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
DECLARE
    submission_row data.assignment_field_submission%ROWTYPE;
    event_kind TEXT;
BEGIN
    IF (TG_OP = 'DELETE') THEN
        submission_row := OLD;
        event_kind := 'deleted';
    ELSE
        submission_row := NEW;
        IF (TG_OP = 'INSERT') THEN
            event_kind := 'submitted';
        ELSE
            event_kind := 'revised';
        END IF;
    END IF;

    INSERT INTO data.assignment_field_submission_event (
        event_type,
        operation,
        assignment_submission_id,
        assignment_field_slug,
        assignment_slug,
        body_sha256,
        body_length,
        submitter_user_id,
        submission_created_at,
        submission_updated_at,
        created_by_user_id
    )
    VALUES (
        event_kind,
        lower(TG_OP),
        submission_row.assignment_submission_id,
        submission_row.assignment_field_slug,
        submission_row.assignment_slug,
        encode(public.digest(submission_row.body, 'sha256'), 'hex'),
        octet_length(submission_row.body),
        submission_row.submitter_user_id,
        submission_row.created_at,
        submission_row.updated_at,
        request.user_id()
    );

    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION data.record_assignment_field_submission_event() OWNER TO yelukerest_migrator;

--
-- Name: record_assignment_grade_event(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.record_assignment_grade_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
DECLARE
    grade_row data.assignment_grade%ROWTYPE;
    event_kind TEXT;
BEGIN
    IF (TG_OP = 'DELETE') THEN
        grade_row := OLD;
        event_kind := 'voided';
    ELSE
        grade_row := NEW;
        IF (TG_OP = 'INSERT') THEN
            event_kind := 'recorded';
        ELSE
            event_kind := 'corrected';
        END IF;
    END IF;

    INSERT INTO data.assignment_grade_event (
        event_type,
        operation,
        assignment_submission_id,
        assignment_slug,
        points_possible,
        points,
        description,
        grade_created_at,
        grade_updated_at,
        created_by_user_id
    )
    VALUES (
        event_kind,
        lower(TG_OP),
        grade_row.assignment_submission_id,
        grade_row.assignment_slug,
        grade_row.points_possible,
        grade_row.points,
        grade_row.description,
        grade_row.created_at,
        grade_row.updated_at,
        request.user_id()
    );

    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION data.record_assignment_grade_event() OWNER TO yelukerest_migrator;

--
-- Name: record_grade_event(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.record_grade_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
DECLARE
    grade_row data.grade%ROWTYPE;
    event_kind TEXT;
BEGIN
    IF (TG_OP = 'DELETE') THEN
        grade_row := OLD;
        event_kind := 'voided';
    ELSE
        grade_row := NEW;
        IF (TG_OP = 'INSERT') THEN
            event_kind := 'recorded';
        ELSE
            event_kind := 'corrected';
        END IF;
    END IF;

    INSERT INTO data.grade_event (
        event_type,
        operation,
        snapshot_slug,
        user_id,
        points,
        description,
        grade_created_at,
        grade_updated_at,
        created_by_user_id
    )
    VALUES (
        event_kind,
        lower(TG_OP),
        grade_row.snapshot_slug,
        grade_row.user_id,
        grade_row.points,
        grade_row.description,
        grade_row.created_at,
        grade_row.updated_at,
        request.user_id()
    );

    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION data.record_grade_event() OWNER TO yelukerest_migrator;

--
-- Name: record_quiz_grade_event(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.record_quiz_grade_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
DECLARE
    grade_row data.quiz_grade%ROWTYPE;
    event_kind TEXT;
BEGIN
    IF (TG_OP = 'DELETE') THEN
        grade_row := OLD;
        event_kind := 'voided';
    ELSE
        grade_row := NEW;
        IF (TG_OP = 'INSERT') THEN
            event_kind := 'recorded';
        ELSE
            event_kind := 'corrected';
        END IF;
    END IF;

    INSERT INTO data.quiz_grade_event (
        event_type,
        operation,
        quiz_id,
        user_id,
        points,
        points_possible,
        description,
        grade_created_at,
        grade_updated_at,
        created_by_user_id
    )
    VALUES (
        event_kind,
        lower(TG_OP),
        grade_row.quiz_id,
        grade_row.user_id,
        grade_row.points,
        grade_row.points_possible,
        grade_row.description,
        grade_row.created_at,
        grade_row.updated_at,
        request.user_id()
    );

    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION data.record_quiz_grade_event() OWNER TO yelukerest_migrator;

--
-- Name: refresh_assignment_submission_participants(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.refresh_assignment_submission_participants() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Submission participants are an insert-time snapshot. Later team roster
    -- changes must not rewrite historical submitted work.
    DELETE FROM data.assignment_submission_participant
    WHERE assignment_submission_id = NEW.id;

    IF (NEW.is_team) THEN
        INSERT INTO data.assignment_submission_participant (assignment_submission_id, user_id)
        SELECT NEW.id, u.id
        FROM data."user" AS u
        WHERE u.team_nickname = NEW.team_nickname;
    ELSE
        INSERT INTO data.assignment_submission_participant (assignment_submission_id, user_id)
        SELECT NEW.id, NEW.user_id
        WHERE NEW.user_id IS NOT NULL;
    END IF;

    RETURN NULL;
END;
$$;


ALTER FUNCTION data.refresh_assignment_submission_participants() OWNER TO yelukerest_migrator;

--
-- Name: text_is_url(text); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.text_is_url(text) RETURNS boolean
    LANGUAGE sql STABLE
    RETURN ((char_length($1) <= 2048) AND ($1 ~* '^https?://[a-z0-9]+'::text));


ALTER FUNCTION data.text_is_url(text) OWNER TO yelukerest_migrator;

--
-- Name: text_matches(text, text); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.text_matches(text, text) RETURNS boolean
    LANGUAGE sql STABLE
    RETURN ($1 ~ (('^(?:'::text || $2) || ')$'::text));


ALTER FUNCTION data.text_matches(text, text) OWNER TO yelukerest_migrator;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: data; Owner: cluster_admin
--

CREATE FUNCTION data.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.update_updated_at_column() OWNER TO yelukerest_migrator;

--
-- Name: algorithm_sign(text, text, text); Type: FUNCTION; Schema: pgjwt; Owner: cluster_admin
--

CREATE FUNCTION pgjwt.algorithm_sign(signables text, secret text, algorithm text) RETURNS text
    LANGUAGE sql
    AS $$
WITH
  alg AS (
    SELECT CASE
      WHEN algorithm = 'HS256' THEN 'sha256'
      WHEN algorithm = 'HS384' THEN 'sha384'
      WHEN algorithm = 'HS512' THEN 'sha512'
      ELSE '' END)  -- hmac throws error
SELECT pgjwt.url_encode(public.hmac(signables, secret, (select * FROM alg)));
$$;


ALTER FUNCTION pgjwt.algorithm_sign(signables text, secret text, algorithm text) OWNER TO yelukerest_migrator;

--
-- Name: url_decode(text); Type: FUNCTION; Schema: pgjwt; Owner: cluster_admin
--

CREATE FUNCTION pgjwt.url_decode(data text) RETURNS bytea
    LANGUAGE sql
    AS $$
WITH t AS (SELECT translate(data, '-_', '+/')),
     rem AS (SELECT length((SELECT * FROM t)) % 4) -- compute padding size
    SELECT decode(
        (SELECT * FROM t) ||
        CASE WHEN (SELECT * FROM rem) > 0
           THEN repeat('=', (4 - (SELECT * FROM rem)))
           ELSE '' END,
    'base64');
$$;


ALTER FUNCTION pgjwt.url_decode(data text) OWNER TO yelukerest_migrator;

--
-- Name: url_encode(bytea); Type: FUNCTION; Schema: pgjwt; Owner: cluster_admin
--

CREATE FUNCTION pgjwt.url_encode(data bytea) RETURNS text
    LANGUAGE sql
    AS $$
    SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;


ALTER FUNCTION pgjwt.url_encode(data bytea) OWNER TO yelukerest_migrator;

--
-- Name: verify(text, text, text); Type: FUNCTION; Schema: pgjwt; Owner: cluster_admin
--

CREATE FUNCTION pgjwt.verify(token text, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS TABLE(header json, payload json, valid boolean)
    LANGUAGE sql
    AS $$
  SELECT
    convert_from(pgjwt.url_decode(r[1]), 'utf8')::json AS header,
    convert_from(pgjwt.url_decode(r[2]), 'utf8')::json AS payload,
    r[3] = pgjwt.algorithm_sign(r[1] || '.' || r[2], secret, algorithm) AS valid
  FROM regexp_split_to_array(token, '\.') r;
$$;


ALTER FUNCTION pgjwt.verify(token text, secret text, algorithm text) OWNER TO yelukerest_migrator;

--
-- Name: set(text, text); Type: FUNCTION; Schema: settings; Owner: cluster_admin
--

CREATE FUNCTION settings.set(text, text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'settings', 'pg_temp'
    BEGIN ATOMIC
 INSERT INTO settings.secrets (key, value)
   VALUES ($1, $2) ON CONFLICT(key) DO UPDATE SET value = $2;
END;


ALTER FUNCTION settings.set(text, text) OWNER TO yelukerest_migrator;

--
-- Name: artifact; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.artifact (
    id integer NOT NULL,
    user_id integer NOT NULL,
    quiz_id integer,
    slug text NOT NULL,
    title text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    url text NOT NULL,
    storage_uri text,
    content_type text,
    content_length bigint,
    checksum_sha256 text,
    is_user_visible boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT artifact_checksum_sha256_check CHECK (((checksum_sha256 IS NULL) OR (checksum_sha256 ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT artifact_content_length_check CHECK (((content_length IS NULL) OR ((content_length >= 0) AND (content_length <= '5368709120'::bigint)))),
    CONSTRAINT artifact_content_type_check CHECK (((content_type IS NULL) OR ((char_length(content_type) <= 255) AND (content_type ~ '^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$'::text)))),
    CONSTRAINT artifact_description_check CHECK ((char_length(description) < 1000)),
    CONSTRAINT artifact_slug_check CHECK (((slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$'::text) AND (char_length(slug) < 100))),
    CONSTRAINT artifact_storage_uri_check CHECK (((storage_uri IS NULL) OR (char_length(storage_uri) < 1000))),
    CONSTRAINT artifact_title_check CHECK ((char_length(title) < 200)),
    CONSTRAINT artifact_url_check CHECK ((data.text_is_url(url) AND (char_length(url) <= 2048))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.artifact OWNER TO yelukerest_migrator;

--
-- Name: artifacts; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.artifacts AS
 SELECT id,
    user_id,
    quiz_id,
    slug,
    title,
    description,
    url,
    storage_uri,
    content_type,
    content_length,
    checksum_sha256,
    is_user_visible,
    created_at,
    updated_at
   FROM data.artifact;


ALTER VIEW api.artifacts OWNER TO api;

--
-- Name: VIEW artifacts; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.artifacts IS 'Student-visible files or links associated with a user and, optionally, a quiz';


--
-- Name: COLUMN artifacts.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.id IS 'Unique artifact id';


--
-- Name: COLUMN artifacts.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.user_id IS 'The user this artifact belongs to';


--
-- Name: COLUMN artifacts.quiz_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.quiz_id IS 'The quiz this artifact is associated with, if any';


--
-- Name: COLUMN artifacts.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.slug IS 'Stable short identifier for this artifact within the user account';


--
-- Name: COLUMN artifacts.title; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.title IS 'Human-readable title for this artifact';


--
-- Name: COLUMN artifacts.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.description IS 'Additional context shown with the artifact';


--
-- Name: COLUMN artifacts.url; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.url IS 'HTTP URL where the artifact can be viewed or downloaded';


--
-- Name: COLUMN artifacts.storage_uri; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.storage_uri IS 'Internal storage location for the artifact, if managed by Yelukerest';


--
-- Name: COLUMN artifacts.content_type; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.content_type IS 'Media type for the artifact content, if known';


--
-- Name: COLUMN artifacts.content_length; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.content_length IS 'Size of the artifact in bytes, if known';


--
-- Name: COLUMN artifacts.checksum_sha256; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.checksum_sha256 IS 'SHA-256 checksum for the artifact content, if known';


--
-- Name: COLUMN artifacts.is_user_visible; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.is_user_visible IS 'Whether the artifact should be visible to the affected student';


--
-- Name: COLUMN artifacts.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.created_at IS 'When this artifact row was created';


--
-- Name: COLUMN artifacts.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.artifacts.updated_at IS 'When this artifact row was last updated';


--
-- Name: assignment_field_submission_event; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.assignment_field_submission_event (
    id bigint NOT NULL,
    event_type text NOT NULL,
    operation text NOT NULL,
    assignment_submission_id integer CONSTRAINT assignment_field_submission_e_assignment_submission_id_not_null NOT NULL,
    assignment_field_slug text CONSTRAINT assignment_field_submission_even_assignment_field_slug_not_null NOT NULL,
    assignment_slug text NOT NULL,
    body_sha256 text NOT NULL,
    body_length integer NOT NULL,
    submitter_user_id integer,
    submission_created_at timestamp with time zone CONSTRAINT assignment_field_submission_even_submission_created_at_not_null NOT NULL,
    submission_updated_at timestamp with time zone CONSTRAINT assignment_field_submission_even_submission_updated_at_not_null NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by_user_id integer,
    CONSTRAINT assignment_field_submission_event_assignment_field_slug_check CHECK ((char_length(assignment_field_slug) < 100)),
    CONSTRAINT assignment_field_submission_event_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT assignment_field_submission_event_body_length_check CHECK ((body_length >= 0)),
    CONSTRAINT assignment_field_submission_event_body_sha256_check CHECK ((body_sha256 ~ '^[a-f0-9]{64}$'::text)),
    CONSTRAINT assignment_field_submission_event_event_type_check CHECK ((event_type = ANY (ARRAY['submitted'::text, 'revised'::text, 'deleted'::text]))),
    CONSTRAINT assignment_field_submission_event_operation_check CHECK ((operation = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text])))
);


ALTER TABLE data.assignment_field_submission_event OWNER TO yelukerest_migrator;

--
-- Name: assignment_field_submission_events; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_field_submission_events AS
 SELECT id,
    event_type,
    operation,
    assignment_submission_id,
    assignment_field_slug,
    assignment_slug,
    body_sha256,
    body_length,
    submitter_user_id,
    submission_created_at,
    submission_updated_at,
    created_at,
    created_by_user_id
   FROM data.assignment_field_submission_event;


ALTER VIEW api.assignment_field_submission_events OWNER TO api;

--
-- Name: VIEW assignment_field_submission_events; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.assignment_field_submission_events IS 'Append-only history of assignment field submission inserts, updates, and deletions';


--
-- Name: COLUMN assignment_field_submission_events.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.id IS 'Unique assignment field submission history event id';


--
-- Name: COLUMN assignment_field_submission_events.event_type; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.event_type IS 'Submission event kind: submitted, revised, or deleted';


--
-- Name: COLUMN assignment_field_submission_events.operation; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.operation IS 'Table operation that produced this event';


--
-- Name: COLUMN assignment_field_submission_events.assignment_submission_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.assignment_submission_id IS 'Submission the affected field value belongs to';


--
-- Name: COLUMN assignment_field_submission_events.assignment_field_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.assignment_field_slug IS 'Assignment field the affected value answers';


--
-- Name: COLUMN assignment_field_submission_events.assignment_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.assignment_slug IS 'Assignment the affected field value belongs to';


--
-- Name: COLUMN assignment_field_submission_events.body_sha256; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.body_sha256 IS 'SHA-256 hash of the written field value';


--
-- Name: COLUMN assignment_field_submission_events.body_length; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.body_length IS 'Length in bytes of the written field value';


--
-- Name: COLUMN assignment_field_submission_events.submitter_user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.submitter_user_id IS 'User recorded as the submitter of the field value';


--
-- Name: COLUMN assignment_field_submission_events.submission_created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.submission_created_at IS 'Field submission row creation timestamp captured for this event';


--
-- Name: COLUMN assignment_field_submission_events.submission_updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.submission_updated_at IS 'Field submission row update timestamp captured for this event';


--
-- Name: COLUMN assignment_field_submission_events.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.created_at IS 'When this history event was appended';


--
-- Name: COLUMN assignment_field_submission_events.created_by_user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submission_events.created_by_user_id IS 'Request user that caused this history event, when available';


--
-- Name: assignment_field_submission; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.assignment_field_submission (
    assignment_submission_id integer NOT NULL,
    assignment_field_slug text NOT NULL,
    assignment_slug text NOT NULL,
    assignment_field_is_url boolean NOT NULL,
    assignment_field_pattern text NOT NULL,
    body text NOT NULL,
    submitter_user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT body_matches_is_url CHECK (((assignment_field_is_url IS FALSE) OR data.text_is_url(body))),
    CONSTRAINT body_matches_pattern CHECK (data.text_matches(body, assignment_field_pattern)),
    CONSTRAINT body_max_length CHECK ((octet_length(body) <= 65536)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_field_submission OWNER TO yelukerest_migrator;

--
-- Name: assignment_field_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_field_submissions AS
 SELECT assignment_submission_id,
    assignment_field_slug,
    assignment_slug,
    assignment_field_is_url,
    assignment_field_pattern,
    body,
    submitter_user_id,
    created_at,
    updated_at
   FROM data.assignment_field_submission;


ALTER VIEW api.assignment_field_submissions OWNER TO api;

--
-- Name: VIEW assignment_field_submissions; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.assignment_field_submissions IS 'Values submitted for individual assignment fields';


--
-- Name: COLUMN assignment_field_submissions.assignment_submission_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submissions.assignment_submission_id IS 'Submission this field value belongs to';


--
-- Name: COLUMN assignment_field_submissions.assignment_field_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submissions.assignment_field_slug IS 'Assignment field this value answers';


--
-- Name: COLUMN assignment_field_submissions.assignment_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submissions.assignment_slug IS 'Assignment this field value belongs to';


--
-- Name: COLUMN assignment_field_submissions.assignment_field_is_url; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submissions.assignment_field_is_url IS 'Copied URL-validation setting for the field';


--
-- Name: COLUMN assignment_field_submissions.assignment_field_pattern; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submissions.assignment_field_pattern IS 'Copied validation pattern for the field';


--
-- Name: COLUMN assignment_field_submissions.body; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submissions.body IS 'Submitted field value';


--
-- Name: COLUMN assignment_field_submissions.submitter_user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submissions.submitter_user_id IS 'User who submitted this field value';


--
-- Name: COLUMN assignment_field_submissions.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submissions.created_at IS 'When this field submission row was created';


--
-- Name: COLUMN assignment_field_submissions.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_field_submissions.updated_at IS 'When this field submission row was last updated';


--
-- Name: assignment; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.assignment (
    slug text NOT NULL,
    points_possible smallint NOT NULL,
    is_draft boolean DEFAULT true NOT NULL,
    is_markdown boolean DEFAULT false,
    is_team boolean DEFAULT false NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_body_check CHECK ((octet_length(body) <= 262144)),
    CONSTRAINT assignment_points_possible_check CHECK ((points_possible >= 0)),
    CONSTRAINT assignment_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 60))),
    CONSTRAINT assignment_title_check CHECK ((char_length(title) < 100)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment OWNER TO yelukerest_migrator;

--
-- Name: assignment_field; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.assignment_field (
    slug text NOT NULL,
    assignment_slug text NOT NULL,
    label text NOT NULL,
    help text NOT NULL,
    placeholder text NOT NULL,
    is_url boolean DEFAULT false NOT NULL,
    is_multiline boolean DEFAULT false NOT NULL,
    display_order smallint DEFAULT 0 NOT NULL,
    pattern text DEFAULT '.*'::text NOT NULL,
    example text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_field_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT assignment_field_example_check CHECK ((char_length(example) <= 1024)),
    CONSTRAINT assignment_field_help_check CHECK ((char_length(help) < 200)),
    CONSTRAINT assignment_field_label_check CHECK ((char_length(label) < 100)),
    CONSTRAINT assignment_field_pattern_check CHECK ((char_length(pattern) <= 512)),
    CONSTRAINT assignment_field_placeholder_check CHECK ((char_length(placeholder) < 100)),
    CONSTRAINT assignment_field_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 30))),
    CONSTRAINT pattern_matches_example CHECK (data.text_matches(example, pattern)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT url_matches_example CHECK (((is_url IS FALSE) OR ((is_url IS TRUE) AND data.text_is_url(example)))),
    CONSTRAINT url_not_multiline CHECK ((NOT (is_url AND is_multiline)))
);


ALTER TABLE data.assignment_field OWNER TO yelukerest_migrator;

--
-- Name: assignment_fields; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_fields WITH (security_barrier='true') AS
 SELECT slug,
    assignment_slug,
    label,
    help,
    placeholder,
    is_url,
    is_multiline,
    display_order,
    pattern,
    example,
    created_at,
    updated_at
   FROM data.assignment_field field
  WHERE ((request.user_role() = 'faculty'::text) OR (EXISTS ( SELECT 1
           FROM data.assignment assignment
          WHERE ((assignment.slug = field.assignment_slug) AND (assignment.is_draft = false)))));


ALTER VIEW api.assignment_fields OWNER TO api;

--
-- Name: VIEW assignment_fields; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.assignment_fields IS 'Input fields students fill out when submitting an assignment';


--
-- Name: COLUMN assignment_fields.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.slug IS 'Short identifier for the field within an assignment';


--
-- Name: COLUMN assignment_fields.assignment_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.assignment_slug IS 'Assignment this field belongs to';


--
-- Name: COLUMN assignment_fields.label; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.label IS 'Short label displayed for the field';


--
-- Name: COLUMN assignment_fields.help; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.help IS 'Help text displayed with the field';


--
-- Name: COLUMN assignment_fields.placeholder; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.placeholder IS 'Placeholder text displayed before a value is entered';


--
-- Name: COLUMN assignment_fields.is_url; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.is_url IS 'Whether submitted values must look like URLs';


--
-- Name: COLUMN assignment_fields.is_multiline; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.is_multiline IS 'Whether the field accepts multiline text';


--
-- Name: COLUMN assignment_fields.display_order; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.display_order IS 'Ordering hint for displaying fields within an assignment';


--
-- Name: COLUMN assignment_fields.pattern; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.pattern IS 'Validation pattern submitted values must match';


--
-- Name: COLUMN assignment_fields.example; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.example IS 'Example value that satisfies the validation pattern';


--
-- Name: COLUMN assignment_fields.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.created_at IS 'When this assignment field row was created';


--
-- Name: COLUMN assignment_fields.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_fields.updated_at IS 'When this assignment field row was last updated';


--
-- Name: assignment_grade; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.assignment_grade (
    assignment_slug text NOT NULL,
    points_possible smallint NOT NULL,
    assignment_submission_id integer NOT NULL,
    points real NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_grade_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT assignment_grade_description_check CHECK (((description IS NULL) OR (octet_length(description) <= 8192))),
    CONSTRAINT points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_grade OWNER TO yelukerest_migrator;

--
-- Name: assignment_submission; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.assignment_submission (
    id integer NOT NULL,
    assignment_slug text NOT NULL,
    is_team boolean NOT NULL,
    user_id integer,
    team_nickname text,
    submitter_user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_submission_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT assignment_submission_team_nickname_check CHECK ((char_length(team_nickname) < 50)),
    CONSTRAINT matches_assignment_is_team CHECK (((is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((NOT is_team) AND (team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT submitter_matches_user_id CHECK ((is_team OR ((NOT is_team) AND (user_id = submitter_user_id)))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_submission OWNER TO yelukerest_migrator;

--
-- Name: assignment_submission_participant; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.assignment_submission_participant (
    assignment_submission_id integer CONSTRAINT assignment_submission_partici_assignment_submission_id_not_null NOT NULL,
    user_id integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE data.assignment_submission_participant OWNER TO yelukerest_migrator;

--
-- Name: assignment_grade_distributions; Type: VIEW; Schema: api; Owner: cluster_admin
--

CREATE VIEW api.assignment_grade_distributions AS
 WITH included_scores AS (
         SELECT assignment.slug AS assignment_slug,
            assignment.points_possible,
            COALESCE(assignment_grade.points, (0)::real) AS points
           FROM (((data.assignment
             JOIN data."user" student ON ((student.role = 'student'::data.user_role)))
             LEFT JOIN data.assignment_submission sub ON (((sub.assignment_slug = assignment.slug) AND (NOT sub.is_team) AND (sub.user_id = student.id))))
             LEFT JOIN data.assignment_grade ON ((assignment_grade.assignment_submission_id = sub.id)))
          WHERE ((NOT assignment.is_team) AND (NOT assignment.is_draft))
        UNION ALL
         SELECT sub.assignment_slug,
            assignment.points_possible,
            COALESCE(assignment_grade.points, (0)::real) AS points
           FROM ((((data.assignment_submission sub
             JOIN data.assignment ON (((assignment.slug = sub.assignment_slug) AND assignment.is_team AND (NOT assignment.is_draft))))
             JOIN data.assignment_submission_participant participant ON ((participant.assignment_submission_id = sub.id)))
             JOIN data."user" student ON (((participant.user_id = student.id) AND (student.role = 'student'::data.user_role))))
             LEFT JOIN data.assignment_grade ON ((assignment_grade.assignment_submission_id = sub.id)))
        )
 SELECT assignment_slug,
    count(*) AS count,
    avg(points) AS average,
    min(points) AS min,
    max(points) AS max,
    max(points_possible) AS points_possible,
    stddev_pop(points) AS stddev,
    array_agg(points ORDER BY points) AS grades
   FROM included_scores
  GROUP BY assignment_slug
 HAVING (count(*) >= 3);


ALTER VIEW api.assignment_grade_distributions OWNER TO yelukerest_migrator;

--
-- Name: VIEW assignment_grade_distributions; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON VIEW api.assignment_grade_distributions IS 'Statics on the grades received by students for each assignment';


--
-- Name: COLUMN assignment_grade_distributions.assignment_slug; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.assignment_grade_distributions.assignment_slug IS 'The slug for the assignment to which these statistics correspond';


--
-- Name: COLUMN assignment_grade_distributions.count; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.assignment_grade_distributions.count IS 'The number of student scores included for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.average; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.assignment_grade_distributions.average IS 'The average score among included students for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.min; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.assignment_grade_distributions.min IS 'The minmum grade among students for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.max; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.assignment_grade_distributions.max IS 'The maximum grade among students for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.points_possible; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.assignment_grade_distributions.points_possible IS 'The number of points possible for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.stddev; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.assignment_grade_distributions.stddev IS 'The standard deviation of included student scores for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.grades; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.assignment_grade_distributions.grades IS 'The included student scores for this assignment in ascending order';


--
-- Name: assignment_grade_event; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.assignment_grade_event (
    id bigint NOT NULL,
    event_type text NOT NULL,
    operation text NOT NULL,
    assignment_submission_id integer NOT NULL,
    assignment_slug text NOT NULL,
    points_possible smallint NOT NULL,
    points real NOT NULL,
    description text,
    grade_created_at timestamp with time zone NOT NULL,
    grade_updated_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by_user_id integer,
    source text DEFAULT 'data.assignment_grade'::text NOT NULL,
    reason text,
    import_id text,
    CONSTRAINT assignment_grade_event_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT assignment_grade_event_event_type_check CHECK ((event_type = ANY (ARRAY['recorded'::text, 'corrected'::text, 'voided'::text]))),
    CONSTRAINT assignment_grade_event_operation_check CHECK ((operation = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text]))),
    CONSTRAINT assignment_grade_event_points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision))),
    CONSTRAINT assignment_grade_event_points_possible_check CHECK ((points_possible >= 0))
);


ALTER TABLE data.assignment_grade_event OWNER TO yelukerest_migrator;

--
-- Name: assignment_grade_events; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_grade_events AS
 SELECT id,
    event_type,
    operation,
    assignment_submission_id,
    assignment_slug,
    points_possible,
    points,
    description,
    grade_created_at,
    grade_updated_at,
    created_at,
    created_by_user_id,
    source,
    reason,
    import_id
   FROM data.assignment_grade_event;


ALTER VIEW api.assignment_grade_events OWNER TO api;

--
-- Name: VIEW assignment_grade_events; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.assignment_grade_events IS 'Append-only history of assignment grade inserts, corrections, and deletions';


--
-- Name: COLUMN assignment_grade_events.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.id IS 'Unique assignment grade history event id';


--
-- Name: COLUMN assignment_grade_events.event_type; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.event_type IS 'Grade event kind: recorded, corrected, or voided';


--
-- Name: COLUMN assignment_grade_events.operation; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.operation IS 'Table operation that produced this event';


--
-- Name: COLUMN assignment_grade_events.assignment_submission_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.assignment_submission_id IS 'Submission this grade event evaluates';


--
-- Name: COLUMN assignment_grade_events.assignment_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.assignment_slug IS 'Assignment this grade event belongs to';


--
-- Name: COLUMN assignment_grade_events.points_possible; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.points_possible IS 'Maximum score captured when the event was recorded';


--
-- Name: COLUMN assignment_grade_events.points; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.points IS 'Points captured for this event';


--
-- Name: COLUMN assignment_grade_events.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.description IS 'Optional grading note captured for this event';


--
-- Name: COLUMN assignment_grade_events.grade_created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.grade_created_at IS 'Current-grade row creation timestamp captured for this event';


--
-- Name: COLUMN assignment_grade_events.grade_updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.grade_updated_at IS 'Current-grade row update timestamp captured for this event';


--
-- Name: COLUMN assignment_grade_events.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.created_at IS 'When this history event was appended';


--
-- Name: COLUMN assignment_grade_events.created_by_user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.created_by_user_id IS 'Request user that caused this history event, when available';


--
-- Name: COLUMN assignment_grade_events.source; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.source IS 'Source table or import path that produced this event';


--
-- Name: COLUMN assignment_grade_events.reason; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.reason IS 'Optional reason for the grade event';


--
-- Name: COLUMN assignment_grade_events.import_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_events.import_id IS 'Optional import batch identifier for the grade event';


--
-- Name: assignment_grade_exception; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.assignment_grade_exception (
    id integer NOT NULL,
    assignment_slug text NOT NULL,
    is_team boolean NOT NULL,
    user_id integer,
    team_nickname text,
    fractional_credit numeric DEFAULT 1 NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_grade_exception_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT assignment_grade_exception_fractional_credit_check CHECK (((fractional_credit >= (0)::numeric) AND (fractional_credit <= (1)::numeric))),
    CONSTRAINT assignment_grade_exception_team_nickname_check CHECK ((char_length(team_nickname) < 50)),
    CONSTRAINT matches_assignment_is_team CHECK (((is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((NOT is_team) AND (team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_grade_exception OWNER TO yelukerest_migrator;

--
-- Name: assignment_grade_exceptions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_grade_exceptions AS
 SELECT id,
    assignment_slug,
    is_team,
    user_id,
    team_nickname,
    fractional_credit,
    closed_at,
    created_at,
    updated_at
   FROM data.assignment_grade_exception;


ALTER VIEW api.assignment_grade_exceptions OWNER TO api;

--
-- Name: VIEW assignment_grade_exceptions; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.assignment_grade_exceptions IS 'Per-user or per-team assignment deadline and credit exceptions';


--
-- Name: COLUMN assignment_grade_exceptions.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_exceptions.id IS 'Unique assignment grade exception id';


--
-- Name: COLUMN assignment_grade_exceptions.assignment_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_exceptions.assignment_slug IS 'Assignment this exception applies to';


--
-- Name: COLUMN assignment_grade_exceptions.is_team; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_exceptions.is_team IS 'Whether this exception applies to a team';


--
-- Name: COLUMN assignment_grade_exceptions.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_exceptions.user_id IS 'Student this individual exception applies to';


--
-- Name: COLUMN assignment_grade_exceptions.team_nickname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_exceptions.team_nickname IS 'Team this team exception applies to';


--
-- Name: COLUMN assignment_grade_exceptions.fractional_credit; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_exceptions.fractional_credit IS 'Fraction of normal credit available under this exception';


--
-- Name: COLUMN assignment_grade_exceptions.closed_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_exceptions.closed_at IS 'Exception-specific deadline';


--
-- Name: COLUMN assignment_grade_exceptions.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_exceptions.created_at IS 'When this exception row was created';


--
-- Name: COLUMN assignment_grade_exceptions.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grade_exceptions.updated_at IS 'When this exception row was last updated';


--
-- Name: assignment_grades; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_grades AS
 SELECT assignment_slug,
    points_possible,
    assignment_submission_id,
    points,
    description,
    created_at,
    updated_at
   FROM data.assignment_grade;


ALTER VIEW api.assignment_grades OWNER TO api;

--
-- Name: VIEW assignment_grades; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.assignment_grades IS 'Grades assigned to submitted assignments';


--
-- Name: COLUMN assignment_grades.assignment_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grades.assignment_slug IS 'Assignment this grade belongs to';


--
-- Name: COLUMN assignment_grades.points_possible; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grades.points_possible IS 'Maximum score for the assignment';


--
-- Name: COLUMN assignment_grades.assignment_submission_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grades.assignment_submission_id IS 'Submission this grade evaluates';


--
-- Name: COLUMN assignment_grades.points; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grades.points IS 'Points awarded for the submission';


--
-- Name: COLUMN assignment_grades.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grades.description IS 'Optional grading note or explanation';


--
-- Name: COLUMN assignment_grades.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grades.created_at IS 'When this grade row was created';


--
-- Name: COLUMN assignment_grades.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_grades.updated_at IS 'When this grade row was last updated';


--
-- Name: assignment_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_submissions AS
 SELECT id,
    assignment_slug,
    is_team,
    user_id,
    team_nickname,
    submitter_user_id,
    created_at,
    updated_at
   FROM data.assignment_submission;


ALTER VIEW api.assignment_submissions OWNER TO api;

--
-- Name: VIEW assignment_submissions; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.assignment_submissions IS 'Submitted assignment attempts by individual students or teams';


--
-- Name: COLUMN assignment_submissions.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_submissions.id IS 'Unique assignment submission id';


--
-- Name: COLUMN assignment_submissions.assignment_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_submissions.assignment_slug IS 'Assignment this submission answers';


--
-- Name: COLUMN assignment_submissions.is_team; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_submissions.is_team IS 'Whether this submission belongs to a team';


--
-- Name: COLUMN assignment_submissions.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_submissions.user_id IS 'Student who owns an individual submission';


--
-- Name: COLUMN assignment_submissions.team_nickname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_submissions.team_nickname IS 'Team that owns a team submission';


--
-- Name: COLUMN assignment_submissions.submitter_user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_submissions.submitter_user_id IS 'User who created the submission';


--
-- Name: COLUMN assignment_submissions.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_submissions.created_at IS 'When this submission row was created';


--
-- Name: COLUMN assignment_submissions.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignment_submissions.updated_at IS 'When this submission row was last updated';


--
-- Name: assignments; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignments WITH (security_barrier='true') AS
 SELECT slug,
    points_possible,
    is_draft,
    is_markdown,
    is_team,
    title,
    body,
    closed_at,
    created_at,
    updated_at,
    ((is_draft = false) AND (CURRENT_TIMESTAMP < closed_at)) AS is_open
   FROM data.assignment
  WHERE ((request.user_role() = 'faculty'::text) OR (is_draft = false));


ALTER VIEW api.assignments OWNER TO api;

--
-- Name: VIEW assignments; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.assignments IS 'Assignments that students can view or submit, with draft rows reserved for faculty';


--
-- Name: COLUMN assignments.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.slug IS 'Short identifier for the assignment';


--
-- Name: COLUMN assignments.points_possible; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.points_possible IS 'Maximum score for the assignment';


--
-- Name: COLUMN assignments.is_draft; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.is_draft IS 'Whether the assignment is still hidden from students and TAs';


--
-- Name: COLUMN assignments.is_markdown; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.is_markdown IS 'Whether the assignment body should be rendered as Markdown';


--
-- Name: COLUMN assignments.is_team; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.is_team IS 'Whether submissions are made by teams instead of individuals';


--
-- Name: COLUMN assignments.title; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.title IS 'Human-readable assignment title';


--
-- Name: COLUMN assignments.body; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.body IS 'Assignment instructions or content';


--
-- Name: COLUMN assignments.closed_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.closed_at IS 'Deadline after which normal submissions are closed';


--
-- Name: COLUMN assignments.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.created_at IS 'When this assignment row was created';


--
-- Name: COLUMN assignments.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.updated_at IS 'When this assignment row was last updated';


--
-- Name: COLUMN assignments.is_open; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.assignments.is_open IS 'Whether the assignment is published and still open for normal submission';


--
-- Name: engagement; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.engagement (
    user_id integer NOT NULL,
    meeting_slug text NOT NULL,
    participation data.participation_enum NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT engagement_meeting_slug_check CHECK ((char_length(meeting_slug) < 100)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.engagement OWNER TO yelukerest_migrator;

--
-- Name: engagements; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.engagements AS
 SELECT user_id,
    meeting_slug,
    participation,
    created_at,
    updated_at
   FROM data.engagement;


ALTER VIEW api.engagements OWNER TO api;

--
-- Name: VIEW engagements; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.engagements IS 'Attendance and participation records for users at class meetings';


--
-- Name: COLUMN engagements.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.engagements.user_id IS 'User whose participation is recorded';


--
-- Name: COLUMN engagements.meeting_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.engagements.meeting_slug IS 'Meeting this engagement record belongs to';


--
-- Name: COLUMN engagements.participation; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.engagements.participation IS 'Recorded participation status';


--
-- Name: COLUMN engagements.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.engagements.created_at IS 'When this engagement row was created';


--
-- Name: COLUMN engagements.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.engagements.updated_at IS 'When this engagement row was last updated';


--
-- Name: grade_event; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.grade_event (
    id bigint NOT NULL,
    event_type text NOT NULL,
    operation text NOT NULL,
    snapshot_slug text NOT NULL,
    user_id integer NOT NULL,
    points real NOT NULL,
    description text,
    grade_created_at timestamp with time zone NOT NULL,
    grade_updated_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by_user_id integer,
    source text DEFAULT 'data.grade'::text NOT NULL,
    reason text,
    import_id text,
    CONSTRAINT grade_event_event_type_check CHECK ((event_type = ANY (ARRAY['recorded'::text, 'corrected'::text, 'voided'::text]))),
    CONSTRAINT grade_event_operation_check CHECK ((operation = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text]))),
    CONSTRAINT grade_event_points_finite_nonnegative CHECK (((points >= (0)::double precision) AND (points <= (100000)::double precision)))
);


ALTER TABLE data.grade_event OWNER TO yelukerest_migrator;

--
-- Name: grade_events; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.grade_events AS
 SELECT id,
    event_type,
    operation,
    snapshot_slug,
    user_id,
    points,
    description,
    grade_created_at,
    grade_updated_at,
    created_at,
    created_by_user_id,
    source,
    reason,
    import_id
   FROM data.grade_event;


ALTER VIEW api.grade_events OWNER TO api;

--
-- Name: VIEW grade_events; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.grade_events IS 'Append-only history of grade snapshot inserts, corrections, and deletions';


--
-- Name: COLUMN grade_events.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.id IS 'Unique grade snapshot history event id';


--
-- Name: COLUMN grade_events.event_type; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.event_type IS 'Grade event kind: recorded, corrected, or voided';


--
-- Name: COLUMN grade_events.operation; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.operation IS 'Table operation that produced this event';


--
-- Name: COLUMN grade_events.snapshot_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.snapshot_slug IS 'Grade snapshot this history event belongs to';


--
-- Name: COLUMN grade_events.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.user_id IS 'User whose snapshot grade event is recorded';


--
-- Name: COLUMN grade_events.points; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.points IS 'Grade points captured for this event';


--
-- Name: COLUMN grade_events.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.description IS 'Optional grade note captured for this event';


--
-- Name: COLUMN grade_events.grade_created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.grade_created_at IS 'Current-grade row creation timestamp captured for this event';


--
-- Name: COLUMN grade_events.grade_updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.grade_updated_at IS 'Current-grade row update timestamp captured for this event';


--
-- Name: COLUMN grade_events.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.created_at IS 'When this history event was appended';


--
-- Name: COLUMN grade_events.created_by_user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.created_by_user_id IS 'Request user that caused this history event, when available';


--
-- Name: COLUMN grade_events.source; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.source IS 'Source table or import path that produced this event';


--
-- Name: COLUMN grade_events.reason; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.reason IS 'Optional reason for the grade event';


--
-- Name: COLUMN grade_events.import_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_events.import_id IS 'Optional import batch identifier for the grade event';


--
-- Name: grade; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.grade (
    points real NOT NULL,
    snapshot_slug text CONSTRAINT grade_snapshot_slug_not_null1 NOT NULL,
    user_id integer NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT grade_description_check CHECK (((description IS NULL) OR (octet_length(description) <= 8192))),
    CONSTRAINT grade_points_finite_nonnegative CHECK (((points >= (0)::double precision) AND (points <= (100000)::double precision))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.grade OWNER TO yelukerest_migrator;

--
-- Name: grade_snapshot_distributions; Type: VIEW; Schema: api; Owner: cluster_admin
--

CREATE VIEW api.grade_snapshot_distributions AS
 SELECT grade.snapshot_slug,
    count(grade.user_id) AS count,
    avg(grade.points) AS average,
    min(grade.points) AS min,
    max(grade.points) AS max,
    stddev_pop(grade.points) AS stddev,
    array_agg(grade.points ORDER BY grade.points) AS grades
   FROM (data.grade
     JOIN data."user" ON ((grade.user_id = "user".id)))
  WHERE ("user".role = 'student'::data.user_role)
  GROUP BY grade.snapshot_slug
 HAVING (count(grade.user_id) >= 3);


ALTER VIEW api.grade_snapshot_distributions OWNER TO yelukerest_migrator;

--
-- Name: VIEW grade_snapshot_distributions; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON VIEW api.grade_snapshot_distributions IS 'Statistics on student grades for each grade snapshot';


--
-- Name: COLUMN grade_snapshot_distributions.snapshot_slug; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.grade_snapshot_distributions.snapshot_slug IS 'The slug for the grade snapshot to which these statistics correspond';


--
-- Name: COLUMN grade_snapshot_distributions.count; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.grade_snapshot_distributions.count IS 'The number of students with grades for this grade snapshot';


--
-- Name: COLUMN grade_snapshot_distributions.average; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.grade_snapshot_distributions.average IS 'The average grade among students for this grade snapshot';


--
-- Name: COLUMN grade_snapshot_distributions.min; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.grade_snapshot_distributions.min IS 'The minimum grade among students for this grade snapshot';


--
-- Name: COLUMN grade_snapshot_distributions.max; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.grade_snapshot_distributions.max IS 'The maximum grade among students for this grade snapshot';


--
-- Name: COLUMN grade_snapshot_distributions.stddev; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.grade_snapshot_distributions.stddev IS 'The population standard deviation of student grades for this grade snapshot';


--
-- Name: COLUMN grade_snapshot_distributions.grades; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.grade_snapshot_distributions.grades IS 'The student grades for this grade snapshot in ascending order';


--
-- Name: grade_snapshot; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.grade_snapshot (
    slug text NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT grade_snapshot_description_check CHECK (((description IS NULL) OR (octet_length(description) <= 8192))),
    CONSTRAINT grade_snapshot_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 60))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.grade_snapshot OWNER TO yelukerest_migrator;

--
-- Name: grade_snapshots; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.grade_snapshots AS
 SELECT slug,
    description,
    created_at,
    updated_at
   FROM data.grade_snapshot;


ALTER VIEW api.grade_snapshots OWNER TO api;

--
-- Name: VIEW grade_snapshots; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.grade_snapshots IS 'Snapshots of class grades at particular times';


--
-- Name: COLUMN grade_snapshots.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.slug IS 'The slug, or unique identifier, of this grade snapshot';


--
-- Name: COLUMN grade_snapshots.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.description IS 'The description of this grade snapshot. This might tell you how the grades were computed for this snapshot.';


--
-- Name: COLUMN grade_snapshots.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.created_at IS 'When this snapshot was created';


--
-- Name: COLUMN grade_snapshots.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.updated_at IS 'When this snapshot was last updated';


--
-- Name: grades; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.grades AS
 SELECT points,
    snapshot_slug,
    user_id,
    description,
    created_at,
    updated_at
   FROM data.grade;


ALTER VIEW api.grades OWNER TO api;

--
-- Name: VIEW grades; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.grades IS 'Per-student grade values within named grade snapshots';


--
-- Name: COLUMN grades.points; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grades.points IS 'Grade points recorded in the snapshot';


--
-- Name: COLUMN grades.snapshot_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grades.snapshot_slug IS 'Grade snapshot this row belongs to';


--
-- Name: COLUMN grades.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grades.user_id IS 'User whose snapshot grade is recorded';


--
-- Name: COLUMN grades.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grades.description IS 'Optional note explaining the snapshot grade';


--
-- Name: COLUMN grades.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grades.created_at IS 'When this grade snapshot row was created';


--
-- Name: COLUMN grades.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grades.updated_at IS 'When this grade snapshot row was last updated';


--
-- Name: mcp_grant_revocation; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.mcp_grant_revocation (
    id bigint NOT NULL,
    user_id integer NOT NULL,
    netid text NOT NULL,
    client_id text NOT NULL,
    client_name text,
    scopes text,
    revoked_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT mcp_grant_revocation_client_id_check CHECK (((char_length(client_id) > 0) AND (char_length(client_id) <= 500))),
    CONSTRAINT mcp_grant_revocation_client_name_check CHECK ((char_length(client_name) <= 500)),
    CONSTRAINT mcp_grant_revocation_netid_check CHECK ((char_length(netid) < 100)),
    CONSTRAINT mcp_grant_revocation_scopes_check CHECK ((char_length(scopes) <= 1024))
);


ALTER TABLE data.mcp_grant_revocation OWNER TO yelukerest_migrator;

--
-- Name: mcp_grant_revocations; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.mcp_grant_revocations AS
 SELECT id,
    user_id,
    netid,
    client_id,
    client_name,
    scopes,
    revoked_at
   FROM data.mcp_grant_revocation;


ALTER VIEW api.mcp_grant_revocations OWNER TO api;

--
-- Name: VIEW mcp_grant_revocations; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.mcp_grant_revocations IS 'Append-only record of MCP application grants a user disconnected; the mint path refuses tokens issued before the revocation';


--
-- Name: COLUMN mcp_grant_revocations.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_grant_revocations.id IS 'Unique revocation id';


--
-- Name: COLUMN mcp_grant_revocations.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_grant_revocations.user_id IS 'User who disconnected the application';


--
-- Name: COLUMN mcp_grant_revocations.netid; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_grant_revocations.netid IS 'Netid of the user who disconnected the application';


--
-- Name: COLUMN mcp_grant_revocations.client_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_grant_revocations.client_id IS 'OAuth client id that was disconnected';


--
-- Name: COLUMN mcp_grant_revocations.client_name; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_grant_revocations.client_name IS 'Human-readable client name captured at disconnect time';


--
-- Name: COLUMN mcp_grant_revocations.scopes; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_grant_revocations.scopes IS 'Space-separated scopes the grant could reach when it was cut off';


--
-- Name: COLUMN mcp_grant_revocations.revoked_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_grant_revocations.revoked_at IS 'When the user disconnected the application';


--
-- Name: mcp_jwt_mint_event; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.mcp_jwt_mint_event (
    id bigint NOT NULL,
    user_id integer NOT NULL,
    netid text NOT NULL,
    user_role text NOT NULL,
    scopes text NOT NULL,
    jti text NOT NULL,
    caller_app_name text NOT NULL,
    external_issuer text,
    external_sub text,
    external_jti text,
    external_client_id text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT mcp_jwt_mint_event_caller_app_name_check CHECK ((char_length(caller_app_name) < 100)),
    CONSTRAINT mcp_jwt_mint_event_external_client_id_check CHECK ((char_length(external_client_id) <= 500)),
    CONSTRAINT mcp_jwt_mint_event_external_issuer_check CHECK ((char_length(external_issuer) <= 500)),
    CONSTRAINT mcp_jwt_mint_event_external_jti_check CHECK ((char_length(external_jti) <= 500)),
    CONSTRAINT mcp_jwt_mint_event_external_sub_check CHECK ((char_length(external_sub) <= 500)),
    CONSTRAINT mcp_jwt_mint_event_jti_check CHECK ((jti ~ '^[0-9a-f-]{36}$'::text)),
    CONSTRAINT mcp_jwt_mint_event_netid_check CHECK ((char_length(netid) < 100)),
    CONSTRAINT mcp_jwt_mint_event_scopes_check CHECK ((char_length(scopes) <= 1024)),
    CONSTRAINT mcp_jwt_mint_event_user_role_check CHECK ((char_length(user_role) < 100))
);


ALTER TABLE data.mcp_jwt_mint_event OWNER TO yelukerest_migrator;

--
-- Name: mcp_jwt_mint_anomalies; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.mcp_jwt_mint_anomalies AS
 SELECT caller_app_name,
    created_at AS window_end,
    (created_at - '00:10:00'::interval) AS window_start,
    ( SELECT count(DISTINCT p.user_id) AS count
           FROM data.mcp_jwt_mint_event p
          WHERE ((p.caller_app_name = e.caller_app_name) AND (p.created_at > (e.created_at - '00:10:00'::interval)) AND (p.created_at <= e.created_at))) AS distinct_subjects,
    ( SELECT count(*) AS count
           FROM data.mcp_jwt_mint_event p
          WHERE ((p.caller_app_name = e.caller_app_name) AND (p.created_at > (e.created_at - '00:10:00'::interval)) AND (p.created_at <= e.created_at))) AS mint_count
   FROM data.mcp_jwt_mint_event e
  WHERE (( SELECT count(DISTINCT p.user_id) AS count
           FROM data.mcp_jwt_mint_event p
          WHERE ((p.caller_app_name = e.caller_app_name) AND (p.created_at > (e.created_at - '00:10:00'::interval)) AND (p.created_at <= e.created_at))) > 10);


ALTER VIEW api.mcp_jwt_mint_anomalies OWNER TO api;

--
-- Name: VIEW mcp_jwt_mint_anomalies; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.mcp_jwt_mint_anomalies IS 'Mint-rate anomaly report: callers minting JWTs for more than 10 distinct users within a 10-minute window';


--
-- Name: COLUMN mcp_jwt_mint_anomalies.caller_app_name; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_anomalies.caller_app_name IS 'Service credential whose minting rate looks anomalous';


--
-- Name: COLUMN mcp_jwt_mint_anomalies.window_end; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_anomalies.window_end IS 'End of the sliding 10-minute window: the mint event that tripped the threshold';


--
-- Name: COLUMN mcp_jwt_mint_anomalies.window_start; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_anomalies.window_start IS 'Start of the sliding 10-minute window containing the anomalous minting';


--
-- Name: COLUMN mcp_jwt_mint_anomalies.distinct_subjects; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_anomalies.distinct_subjects IS 'Distinct users minted for within the window';


--
-- Name: COLUMN mcp_jwt_mint_anomalies.mint_count; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_anomalies.mint_count IS 'Total mint events within the window';


--
-- Name: mcp_jwt_mint_events; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.mcp_jwt_mint_events AS
 SELECT id,
    user_id,
    netid,
    user_role,
    scopes,
    jti,
    caller_app_name,
    external_issuer,
    external_sub,
    external_jti,
    external_client_id,
    created_at
   FROM data.mcp_jwt_mint_event;


ALTER VIEW api.mcp_jwt_mint_events OWNER TO api;

--
-- Name: VIEW mcp_jwt_mint_events; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.mcp_jwt_mint_events IS 'Append-only audit history of internal user JWTs minted for the MCP service';


--
-- Name: COLUMN mcp_jwt_mint_events.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.id IS 'Unique mint event id';


--
-- Name: COLUMN mcp_jwt_mint_events.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.user_id IS 'User the internal JWT was minted for';


--
-- Name: COLUMN mcp_jwt_mint_events.netid; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.netid IS 'Netid the internal JWT was minted for';


--
-- Name: COLUMN mcp_jwt_mint_events.user_role; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.user_role IS 'Course role captured when the internal JWT was minted';


--
-- Name: COLUMN mcp_jwt_mint_events.scopes; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.scopes IS 'Space-separated scopes granted in the minted JWT';


--
-- Name: COLUMN mcp_jwt_mint_events.jti; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.jti IS 'Token id (jti claim) of the minted internal JWT';


--
-- Name: COLUMN mcp_jwt_mint_events.caller_app_name; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.caller_app_name IS 'app_name claim of the service credential that requested the mint';


--
-- Name: COLUMN mcp_jwt_mint_events.external_issuer; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.external_issuer IS 'Issuer of the external token exchanged for this JWT, if any';


--
-- Name: COLUMN mcp_jwt_mint_events.external_sub; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.external_sub IS 'Subject of the external token exchanged for this JWT, if any';


--
-- Name: COLUMN mcp_jwt_mint_events.external_jti; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.external_jti IS 'Token id of the external token exchanged for this JWT, if any';


--
-- Name: COLUMN mcp_jwt_mint_events.external_client_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.external_client_id IS 'OAuth client id associated with the external token, if any';


--
-- Name: COLUMN mcp_jwt_mint_events.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.mcp_jwt_mint_events.created_at IS 'When this mint event was appended';


--
-- Name: meeting; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.meeting (
    title text NOT NULL,
    slug text NOT NULL,
    summary text,
    description text NOT NULL,
    begins_at timestamp with time zone NOT NULL,
    duration interval NOT NULL,
    meeting_type data.meeting_type_enum DEFAULT 'lecture'::data.meeting_type_enum NOT NULL,
    is_draft boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT meeting_description_check CHECK ((octet_length(description) <= 262144)),
    CONSTRAINT meeting_duration_max CHECK ((duration <= '24:00:00'::interval)),
    CONSTRAINT meeting_duration_positive CHECK ((duration > '00:00:00'::interval)),
    CONSTRAINT meeting_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 60))),
    CONSTRAINT meeting_summary_check CHECK (((summary IS NULL) OR (octet_length(summary) <= 4096))),
    CONSTRAINT meeting_title_check CHECK ((char_length(title) < 250)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.meeting OWNER TO yelukerest_migrator;

--
-- Name: meetings; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.meetings AS
 SELECT title,
    slug,
    summary,
    description,
    begins_at,
    duration,
    meeting_type,
    is_draft,
    created_at,
    updated_at
   FROM data.meeting;


ALTER VIEW api.meetings OWNER TO api;

--
-- Name: VIEW meetings; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.meetings IS 'An in-person meeting of our class, usually a lecture';


--
-- Name: COLUMN meetings.title; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.title IS 'Human-readable title for the meeting';


--
-- Name: COLUMN meetings.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.slug IS 'A short identifier, appropriate for URLs, like "sql-intro"';


--
-- Name: COLUMN meetings.summary; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.summary IS 'A short description of the meeting in Markdown format';


--
-- Name: COLUMN meetings.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.description IS 'A long description of the meeting in Markdown format';


--
-- Name: COLUMN meetings.begins_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.begins_at IS 'The time at which the meeting begins, including timezone';


--
-- Name: COLUMN meetings.duration; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.duration IS 'The duration of the meeting as a Postgres interval';


--
-- Name: COLUMN meetings.meeting_type; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.meeting_type IS 'The kind of meeting, such as lecture, no-meeting, or office-hours';


--
-- Name: COLUMN meetings.is_draft; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.is_draft IS 'An indicator of if the content is still changing';


--
-- Name: COLUMN meetings.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.created_at IS 'The time this database entry was created, including timezone';


--
-- Name: COLUMN meetings.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.updated_at IS 'The most recent time this database entry was updated, including timezone';


--
-- Name: platform_version; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.platform_version AS
 SELECT 'yelukerest'::text AS platform,
    1 AS platform_compatibility_version,
    3 AS schema_compatibility_version,
    5 AS admin_api_version;


ALTER VIEW api.platform_version OWNER TO api;

--
-- Name: VIEW platform_version; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.platform_version IS 'Single-row compatibility metadata for course admin preflight checks';


--
-- Name: COLUMN platform_version.platform; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.platform_version.platform IS 'Platform identifier expected by course admin tooling';


--
-- Name: COLUMN platform_version.platform_compatibility_version; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.platform_version.platform_compatibility_version IS 'Integer compatibility version for Yelukerest platform behavior';


--
-- Name: COLUMN platform_version.schema_compatibility_version; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.platform_version.schema_compatibility_version IS 'Integer compatibility version for database schema/API shape';


--
-- Name: COLUMN platform_version.admin_api_version; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.platform_version.admin_api_version IS 'Integer compatibility version for generic admin API operations';


--
-- Name: quiz_grade; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.quiz_grade (
    quiz_id integer NOT NULL,
    points real NOT NULL,
    points_possible smallint NOT NULL,
    description text,
    user_id integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision))),
    CONSTRAINT quiz_grade_description_check CHECK (((description IS NULL) OR (octet_length(description) <= 8192))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_grade OWNER TO yelukerest_migrator;

--
-- Name: quiz_grade_distributions; Type: VIEW; Schema: api; Owner: cluster_admin
--

CREATE VIEW api.quiz_grade_distributions AS
 SELECT quiz_grade.quiz_id,
    count(quiz_grade.user_id) AS count,
    avg(quiz_grade.points) AS average,
    min(quiz_grade.points) AS min,
    max(quiz_grade.points) AS max,
    max(quiz_grade.points_possible) AS points_possible,
    stddev_pop(quiz_grade.points) AS stddev,
    array_agg(quiz_grade.points ORDER BY quiz_grade.points) AS grades
   FROM (data.quiz_grade
     JOIN data."user" ON ((quiz_grade.user_id = "user".id)))
  WHERE ("user".role = 'student'::data.user_role)
  GROUP BY quiz_grade.quiz_id
 HAVING (count(quiz_grade.user_id) >= 3);


ALTER VIEW api.quiz_grade_distributions OWNER TO yelukerest_migrator;

--
-- Name: VIEW quiz_grade_distributions; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON VIEW api.quiz_grade_distributions IS 'Statics on the grades received by students for each quiz';


--
-- Name: COLUMN quiz_grade_distributions.quiz_id; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.quiz_grade_distributions.quiz_id IS 'The slug for the quiz to which these statistics correspond';


--
-- Name: COLUMN quiz_grade_distributions.count; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.quiz_grade_distributions.count IS 'The number of students with grades for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.average; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.quiz_grade_distributions.average IS 'The average grade among students for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.min; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.quiz_grade_distributions.min IS 'The minmum grade among students for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.max; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.quiz_grade_distributions.max IS 'The maximum grade among students for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.points_possible; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.quiz_grade_distributions.points_possible IS 'The number of points possible for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.stddev; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.quiz_grade_distributions.stddev IS 'The standard deviation of student grades for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.grades; Type: COMMENT; Schema: api; Owner: cluster_admin
--

COMMENT ON COLUMN api.quiz_grade_distributions.grades IS 'The grades received by students for this quiz in ascending order';


--
-- Name: quiz_grade_event; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.quiz_grade_event (
    id bigint NOT NULL,
    event_type text NOT NULL,
    operation text NOT NULL,
    quiz_id integer NOT NULL,
    user_id integer NOT NULL,
    points real NOT NULL,
    points_possible smallint NOT NULL,
    description text,
    grade_created_at timestamp with time zone NOT NULL,
    grade_updated_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_by_user_id integer,
    source text DEFAULT 'data.quiz_grade'::text NOT NULL,
    reason text,
    import_id text,
    CONSTRAINT quiz_grade_event_event_type_check CHECK ((event_type = ANY (ARRAY['recorded'::text, 'corrected'::text, 'voided'::text]))),
    CONSTRAINT quiz_grade_event_operation_check CHECK ((operation = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text]))),
    CONSTRAINT quiz_grade_event_points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision))),
    CONSTRAINT quiz_grade_event_points_possible_check CHECK ((points_possible >= 0))
);


ALTER TABLE data.quiz_grade_event OWNER TO yelukerest_migrator;

--
-- Name: quiz_grade_events; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_grade_events AS
 SELECT id,
    event_type,
    operation,
    quiz_id,
    user_id,
    points,
    points_possible,
    description,
    grade_created_at,
    grade_updated_at,
    created_at,
    created_by_user_id,
    source,
    reason,
    import_id
   FROM data.quiz_grade_event;


ALTER VIEW api.quiz_grade_events OWNER TO api;

--
-- Name: VIEW quiz_grade_events; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.quiz_grade_events IS 'Append-only history of quiz grade inserts, corrections, and deletions';


--
-- Name: COLUMN quiz_grade_events.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.id IS 'Unique quiz grade history event id';


--
-- Name: COLUMN quiz_grade_events.event_type; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.event_type IS 'Grade event kind: recorded, corrected, or voided';


--
-- Name: COLUMN quiz_grade_events.operation; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.operation IS 'Table operation that produced this event';


--
-- Name: COLUMN quiz_grade_events.quiz_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.quiz_id IS 'Quiz this grade event belongs to';


--
-- Name: COLUMN quiz_grade_events.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.user_id IS 'Student whose quiz grade event is recorded';


--
-- Name: COLUMN quiz_grade_events.points; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.points IS 'Points captured for this event';


--
-- Name: COLUMN quiz_grade_events.points_possible; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.points_possible IS 'Maximum score captured when the event was recorded';


--
-- Name: COLUMN quiz_grade_events.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.description IS 'Optional grading note captured for this event';


--
-- Name: COLUMN quiz_grade_events.grade_created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.grade_created_at IS 'Current-grade row creation timestamp captured for this event';


--
-- Name: COLUMN quiz_grade_events.grade_updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.grade_updated_at IS 'Current-grade row update timestamp captured for this event';


--
-- Name: COLUMN quiz_grade_events.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.created_at IS 'When this history event was appended';


--
-- Name: COLUMN quiz_grade_events.created_by_user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.created_by_user_id IS 'Request user that caused this history event, when available';


--
-- Name: COLUMN quiz_grade_events.source; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.source IS 'Source table or import path that produced this event';


--
-- Name: COLUMN quiz_grade_events.reason; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.reason IS 'Optional reason for the grade event';


--
-- Name: COLUMN quiz_grade_events.import_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_events.import_id IS 'Optional import batch identifier for the grade event';


--
-- Name: quiz_grade_exception; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.quiz_grade_exception (
    id integer NOT NULL,
    quiz_id integer NOT NULL,
    user_id integer NOT NULL,
    fractional_credit numeric DEFAULT 1 NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT quiz_grade_exception_fractional_credit_check CHECK (((fractional_credit >= (0)::numeric) AND (fractional_credit <= (1)::numeric))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_grade_exception OWNER TO yelukerest_migrator;

--
-- Name: quiz_grade_exceptions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_grade_exceptions AS
 SELECT id,
    quiz_id,
    user_id,
    fractional_credit,
    closed_at,
    created_at,
    updated_at
   FROM data.quiz_grade_exception;


ALTER VIEW api.quiz_grade_exceptions OWNER TO api;

--
-- Name: VIEW quiz_grade_exceptions; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.quiz_grade_exceptions IS 'Per-user quiz deadline and credit exceptions';


--
-- Name: COLUMN quiz_grade_exceptions.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_exceptions.id IS 'Unique quiz grade exception id';


--
-- Name: COLUMN quiz_grade_exceptions.quiz_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_exceptions.quiz_id IS 'Quiz this exception applies to';


--
-- Name: COLUMN quiz_grade_exceptions.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_exceptions.user_id IS 'Student this exception applies to';


--
-- Name: COLUMN quiz_grade_exceptions.fractional_credit; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_exceptions.fractional_credit IS 'Fraction of normal credit available under this exception';


--
-- Name: COLUMN quiz_grade_exceptions.closed_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_exceptions.closed_at IS 'Exception-specific quiz deadline';


--
-- Name: COLUMN quiz_grade_exceptions.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_exceptions.created_at IS 'When this quiz grade exception row was created';


--
-- Name: COLUMN quiz_grade_exceptions.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grade_exceptions.updated_at IS 'When this quiz grade exception row was last updated';


--
-- Name: quiz_grades; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_grades AS
 SELECT quiz_id,
    points,
    points_possible,
    description,
    user_id,
    created_at,
    updated_at
   FROM data.quiz_grade;


ALTER VIEW api.quiz_grades OWNER TO api;

--
-- Name: VIEW quiz_grades; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.quiz_grades IS 'Grades assigned to quizzes';


--
-- Name: COLUMN quiz_grades.quiz_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grades.quiz_id IS 'Quiz this grade belongs to';


--
-- Name: COLUMN quiz_grades.points; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grades.points IS 'Points awarded for the quiz';


--
-- Name: COLUMN quiz_grades.points_possible; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grades.points_possible IS 'Maximum score for the quiz';


--
-- Name: COLUMN quiz_grades.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grades.description IS 'Optional grading note or explanation';


--
-- Name: COLUMN quiz_grades.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grades.user_id IS 'Student whose quiz grade is recorded';


--
-- Name: COLUMN quiz_grades.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grades.created_at IS 'When this quiz grade row was created';


--
-- Name: COLUMN quiz_grades.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_grades.updated_at IS 'When this quiz grade row was last updated';


--
-- Name: quiz_submission; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.quiz_submission (
    quiz_id integer NOT NULL,
    user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_submission OWNER TO yelukerest_migrator;

--
-- Name: quiz_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_submissions AS
 SELECT quiz_id,
    user_id,
    created_at,
    updated_at
   FROM data.quiz_submission;


ALTER VIEW api.quiz_submissions OWNER TO api;

--
-- Name: VIEW quiz_submissions; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.quiz_submissions IS 'Student records indicating a quiz submission exists';


--
-- Name: COLUMN quiz_submissions.quiz_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_submissions.quiz_id IS 'Quiz this submission belongs to';


--
-- Name: COLUMN quiz_submissions.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_submissions.user_id IS 'Student who submitted the quiz';


--
-- Name: COLUMN quiz_submissions.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_submissions.created_at IS 'When this quiz submission row was created';


--
-- Name: COLUMN quiz_submissions.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quiz_submissions.updated_at IS 'When this quiz submission row was last updated';


--
-- Name: quiz; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.quiz (
    id integer NOT NULL,
    meeting_slug text NOT NULL,
    points_possible smallint NOT NULL,
    is_draft boolean DEFAULT true NOT NULL,
    open_at timestamp with time zone NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT closed_after_open CHECK ((closed_at > open_at)),
    CONSTRAINT quiz_meeting_slug_check CHECK ((char_length(meeting_slug) < 100)),
    CONSTRAINT quiz_points_possible_check CHECK ((points_possible >= 0)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz OWNER TO yelukerest_migrator;

--
-- Name: quizzes; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quizzes WITH (security_barrier='true') AS
 SELECT id,
    meeting_slug,
    points_possible,
    is_draft,
    open_at,
    closed_at,
    created_at,
    updated_at,
    ((is_draft = false) AND (open_at < CURRENT_TIMESTAMP) AND (CURRENT_TIMESTAMP < closed_at)) AS is_open
   FROM data.quiz
  WHERE ((request.user_role() = 'faculty'::text) OR (is_draft = false));


ALTER VIEW api.quizzes OWNER TO api;

--
-- Name: VIEW quizzes; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.quizzes IS 'Paper quiz metadata and availability windows';


--
-- Name: COLUMN quizzes.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.id IS 'Unique quiz id';


--
-- Name: COLUMN quizzes.meeting_slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.meeting_slug IS 'Meeting associated with the quiz';


--
-- Name: COLUMN quizzes.points_possible; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.points_possible IS 'Maximum score for the quiz';


--
-- Name: COLUMN quizzes.is_offline; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.is_offline IS 'Whether the quiz is administered outside the online app';


--
-- Name: COLUMN quizzes.is_draft; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.is_draft IS 'Whether the quiz is still hidden from students and TAs';


--
-- Name: COLUMN quizzes.duration; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.duration IS 'Nominal time available to complete the quiz';


--
-- Name: COLUMN quizzes.open_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.open_at IS 'When the quiz becomes available';


--
-- Name: COLUMN quizzes.closed_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.closed_at IS 'When the quiz closes';


--
-- Name: COLUMN quizzes.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.created_at IS 'When this quiz row was created';


--
-- Name: COLUMN quizzes.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.updated_at IS 'When this quiz row was last updated';


--
-- Name: COLUMN quizzes.is_open; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.quizzes.is_open IS 'Whether the quiz is published and currently open';


--
-- Name: team; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.team (
    nickname text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT team_nickname_check CHECK ((char_length(nickname) < 50)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT valid_team_nickname CHECK ((nickname ~ '^[\w]{2,20}-[\w]{2,20}$'::text))
);


ALTER TABLE data.team OWNER TO yelukerest_migrator;

--
-- Name: teams; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.teams AS
 SELECT nickname,
    created_at,
    updated_at
   FROM data.team;


ALTER VIEW api.teams OWNER TO api;

--
-- Name: VIEW teams; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.teams IS 'Student teams used for team assignments';


--
-- Name: COLUMN teams.nickname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.teams.nickname IS 'Unique team nickname';


--
-- Name: COLUMN teams.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.teams.created_at IS 'When this team row was created';


--
-- Name: COLUMN teams.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.teams.updated_at IS 'When this team row was last updated';


--
-- Name: ui_element; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.ui_element (
    key text NOT NULL,
    body text,
    is_markdown boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT ui_element_body_check CHECK (((body IS NULL) OR (octet_length(body) <= 65536))),
    CONSTRAINT ui_element_key_check CHECK (((key ~ '^[a-z0-9\-]+$'::text) AND (char_length(key) < 50))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.ui_element OWNER TO yelukerest_migrator;

--
-- Name: ui_elements; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.ui_elements AS
 SELECT key,
    body,
    is_markdown,
    created_at,
    updated_at
   FROM data.ui_element;


ALTER VIEW api.ui_elements OWNER TO api;

--
-- Name: VIEW ui_elements; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.ui_elements IS 'Editable pieces of user-interface copy exposed through the API';


--
-- Name: COLUMN ui_elements.key; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.ui_elements.key IS 'Unique key for the UI element';


--
-- Name: COLUMN ui_elements.body; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.ui_elements.body IS 'Body text for the UI element';


--
-- Name: COLUMN ui_elements.is_markdown; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.ui_elements.is_markdown IS 'Whether the body should be rendered as Markdown';


--
-- Name: COLUMN ui_elements.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.ui_elements.created_at IS 'When this UI element row was created';


--
-- Name: COLUMN ui_elements.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.ui_elements.updated_at IS 'When this UI element row was last updated';


--
-- Name: user_secret; Type: TABLE; Schema: data; Owner: cluster_admin
--

CREATE TABLE data.user_secret (
    id integer NOT NULL,
    slug text NOT NULL,
    body text NOT NULL,
    is_user_visible boolean DEFAULT true NOT NULL,
    user_id integer,
    team_nickname text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT user_or_team CHECK ((((team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT user_secret_body_check CHECK ((octet_length(body) <= 8192)),
    CONSTRAINT user_secret_slug_check CHECK (((slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$'::text) AND (char_length(slug) < 100))),
    CONSTRAINT user_secret_team_nickname_check CHECK ((char_length(team_nickname) < 50))
);


ALTER TABLE data.user_secret OWNER TO yelukerest_migrator;

--
-- Name: user_secrets; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.user_secrets AS
 SELECT id,
    slug,
    body,
    is_user_visible,
    user_id,
    team_nickname,
    created_at,
    updated_at
   FROM data.user_secret;


ALTER VIEW api.user_secrets OWNER TO api;

--
-- Name: VIEW user_secrets; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.user_secrets IS 'Per-user or per-team secret values managed by course staff';


--
-- Name: COLUMN user_secrets.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_secrets.id IS 'Unique user secret id';


--
-- Name: COLUMN user_secrets.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_secrets.slug IS 'Stable short identifier for the secret';


--
-- Name: COLUMN user_secrets.body; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_secrets.body IS 'Secret value';


--
-- Name: COLUMN user_secrets.is_user_visible; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_secrets.is_user_visible IS 'Whether the affected student may read the secret value';


--
-- Name: COLUMN user_secrets.user_id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_secrets.user_id IS 'User this secret belongs to';


--
-- Name: COLUMN user_secrets.team_nickname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_secrets.team_nickname IS 'Team this secret belongs to';


--
-- Name: COLUMN user_secrets.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_secrets.created_at IS 'When this user secret row was created';


--
-- Name: COLUMN user_secrets.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.user_secrets.updated_at IS 'When this user secret row was last updated';


--
-- Name: users; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.users AS
 SELECT id,
    email,
    netid,
    name,
    lastname,
    organization,
    known_as,
    nickname,
    role,
    created_at,
    updated_at,
    team_nickname
   FROM data."user";


ALTER VIEW api.users OWNER TO api;

--
-- Name: VIEW users; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.users IS 'Course users and their public course metadata';


--
-- Name: COLUMN users.id; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.id IS 'Unique user id';


--
-- Name: COLUMN users.email; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.email IS 'User email address';


--
-- Name: COLUMN users.netid; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.netid IS 'University netid for the user';


--
-- Name: COLUMN users.name; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.name IS 'Given name for the user';


--
-- Name: COLUMN users.lastname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.lastname IS 'Family name for the user';


--
-- Name: COLUMN users.organization; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.organization IS 'Organization or school associated with the user';


--
-- Name: COLUMN users.known_as; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.known_as IS 'Preferred display name for the user';


--
-- Name: COLUMN users.nickname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.nickname IS 'Pseudonymous nickname used in class-facing displays';


--
-- Name: COLUMN users.role; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.role IS 'Course role assigned to the user';


--
-- Name: COLUMN users.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.created_at IS 'When this user row was created';


--
-- Name: COLUMN users.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.updated_at IS 'When this user row was last updated';


--
-- Name: COLUMN users.team_nickname; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.users.team_nickname IS 'Team nickname assigned to the user, if any';


--
-- Name: artifact_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.artifact ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.artifact_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: assignment_field_submission_event_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_field_submission_event ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.assignment_field_submission_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: assignment_grade_event_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_grade_event ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.assignment_grade_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: assignment_grade_exception_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_grade_exception ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.assignment_grade_exception_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: assignment_submission_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_submission ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.assignment_submission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: grade_event_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.grade_event ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.grade_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: mcp_grant_revocation_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.mcp_grant_revocation ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.mcp_grant_revocation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: mcp_jwt_mint_event_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.mcp_jwt_mint_event ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.mcp_jwt_mint_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quiz_grade_event_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.quiz_grade_event ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.quiz_grade_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quiz_grade_exception_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.quiz_grade_exception ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.quiz_grade_exception_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quiz_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.quiz ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.quiz_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data."user" ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_secret_id_seq; Type: SEQUENCE; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.user_secret ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.user_secret_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: artifact artifact_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.artifact
    ADD CONSTRAINT artifact_pkey PRIMARY KEY (id);


--
-- Name: artifact artifact_user_slug_unique; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.artifact
    ADD CONSTRAINT artifact_user_slug_unique UNIQUE (user_id, slug);


--
-- Name: assignment_field assignment_field_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_field
    ADD CONSTRAINT assignment_field_pkey PRIMARY KEY (slug, assignment_slug);


--
-- Name: assignment_field assignment_field_slug_assignment_slug_is_url_pattern_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_field
    ADD CONSTRAINT assignment_field_slug_assignment_slug_is_url_pattern_key UNIQUE (slug, assignment_slug, is_url, pattern);


--
-- Name: assignment_field_submission_event assignment_field_submission_event_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_field_submission_event
    ADD CONSTRAINT assignment_field_submission_event_pkey PRIMARY KEY (id);


--
-- Name: assignment_field_submission assignment_field_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_pkey PRIMARY KEY (assignment_submission_id, assignment_field_slug);


--
-- Name: assignment_grade_event assignment_grade_event_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_grade_event
    ADD CONSTRAINT assignment_grade_event_pkey PRIMARY KEY (id);


--
-- Name: assignment_grade_exception assignment_grade_exception_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_pkey PRIMARY KEY (id);


--
-- Name: assignment_grade assignment_grade_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_grade
    ADD CONSTRAINT assignment_grade_pkey PRIMARY KEY (assignment_submission_id);


--
-- Name: assignment assignment_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment
    ADD CONSTRAINT assignment_pkey PRIMARY KEY (slug);


--
-- Name: assignment assignment_slug_is_team_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment
    ADD CONSTRAINT assignment_slug_is_team_key UNIQUE (slug, is_team);


--
-- Name: assignment assignment_slug_points_possible_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment
    ADD CONSTRAINT assignment_slug_points_possible_key UNIQUE (slug, points_possible);


--
-- Name: assignment_submission assignment_submission_id_assignment_slug_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_id_assignment_slug_key UNIQUE (id, assignment_slug);


--
-- Name: assignment_submission_participant assignment_submission_participant_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_submission_participant
    ADD CONSTRAINT assignment_submission_participant_pkey PRIMARY KEY (assignment_submission_id, user_id);


--
-- Name: assignment_submission assignment_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_pkey PRIMARY KEY (id);


--
-- Name: engagement engagement_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.engagement
    ADD CONSTRAINT engagement_pkey PRIMARY KEY (user_id, meeting_slug);


--
-- Name: grade_event grade_event_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.grade_event
    ADD CONSTRAINT grade_event_pkey PRIMARY KEY (id);


--
-- Name: grade_snapshot grade_snapshot_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.grade_snapshot
    ADD CONSTRAINT grade_snapshot_pkey PRIMARY KEY (slug);


--
-- Name: grade grade_snapshot_slug_user_id_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.grade
    ADD CONSTRAINT grade_snapshot_slug_user_id_key UNIQUE (snapshot_slug, user_id);


--
-- Name: mcp_grant_revocation mcp_grant_revocation_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.mcp_grant_revocation
    ADD CONSTRAINT mcp_grant_revocation_pkey PRIMARY KEY (id);


--
-- Name: mcp_jwt_mint_event mcp_jwt_mint_event_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.mcp_jwt_mint_event
    ADD CONSTRAINT mcp_jwt_mint_event_pkey PRIMARY KEY (id);


--
-- Name: meeting meeting_slug_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.meeting
    ADD CONSTRAINT meeting_slug_key UNIQUE (slug);


--
-- Name: quiz_grade_event quiz_grade_event_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_grade_event
    ADD CONSTRAINT quiz_grade_event_pkey PRIMARY KEY (id);


--
-- Name: quiz_grade_exception quiz_grade_exception_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_pkey PRIMARY KEY (id);


--
-- Name: quiz_grade_exception quiz_grade_exception_quiz_id_user_id_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_quiz_id_user_id_key UNIQUE (quiz_id, user_id);


--
-- Name: quiz_grade quiz_grade_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_pkey PRIMARY KEY (quiz_id, user_id);


--
-- Name: quiz quiz_id_points_possible_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_id_points_possible_key UNIQUE (id, points_possible);


--
-- Name: quiz quiz_meeting_slug_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_meeting_slug_key UNIQUE (meeting_slug);


--
-- Name: quiz quiz_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_pkey PRIMARY KEY (id);


--
-- Name: quiz_submission quiz_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_submission
    ADD CONSTRAINT quiz_submission_pkey PRIMARY KEY (quiz_id, user_id);


--
-- Name: team team_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.team
    ADD CONSTRAINT team_pkey PRIMARY KEY (nickname);


--
-- Name: ui_element ui_element_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.ui_element
    ADD CONSTRAINT ui_element_pkey PRIMARY KEY (key);


--
-- Name: user user_email_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_email_key UNIQUE (email);


--
-- Name: user user_netid_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_netid_key UNIQUE (netid);


--
-- Name: user user_nickname_key; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_nickname_key UNIQUE (nickname);


--
-- Name: user user_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_pkey PRIMARY KEY (id);


--
-- Name: user_secret user_secret_pkey; Type: CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.user_secret
    ADD CONSTRAINT user_secret_pkey PRIMARY KEY (id);


--
-- Name: secrets secrets_pkey; Type: CONSTRAINT; Schema: settings; Owner: cluster_admin
--

ALTER TABLE ONLY settings.secrets
    ADD CONSTRAINT secrets_pkey PRIMARY KEY (key);


--
-- Name: assignment_grade_exception_unique_team; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE UNIQUE INDEX assignment_grade_exception_unique_team ON data.assignment_grade_exception USING btree (assignment_slug, team_nickname) WHERE (is_team = true);


--
-- Name: assignment_grade_exception_unique_user; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE UNIQUE INDEX assignment_grade_exception_unique_user ON data.assignment_grade_exception USING btree (assignment_slug, user_id) WHERE (is_team = false);


--
-- Name: assignment_submission_unique_team; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE UNIQUE INDEX assignment_submission_unique_team ON data.assignment_submission USING btree (team_nickname, assignment_slug) WHERE (user_id IS NULL);


--
-- Name: assignment_submission_unique_user; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE UNIQUE INDEX assignment_submission_unique_user ON data.assignment_submission USING btree (user_id, assignment_slug) WHERE (team_nickname IS NULL);


--
-- Name: idx_artifact_quiz_id_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_artifact_quiz_id_fk ON data.artifact USING btree (quiz_id);


--
-- Name: idx_artifact_user_id_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_artifact_user_id_fk ON data.artifact USING btree (user_id);


--
-- Name: idx_assignment_field_assignment_slug_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_field_assignment_slug_fk ON data.assignment_field USING btree (assignment_slug);


--
-- Name: idx_assignment_field_submission_event_actor_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_field_submission_event_actor_fk ON data.assignment_field_submission_event USING btree (created_by_user_id);


--
-- Name: idx_assignment_field_submission_event_natural_key; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_field_submission_event_natural_key ON data.assignment_field_submission_event USING btree (assignment_submission_id, assignment_field_slug, created_at, id);


--
-- Name: idx_assignment_field_submission_field_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_field_submission_field_fk ON data.assignment_field_submission USING btree (assignment_field_slug, assignment_slug, assignment_field_is_url, assignment_field_pattern);


--
-- Name: idx_assignment_field_submission_submission_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_field_submission_submission_fk ON data.assignment_field_submission USING btree (assignment_submission_id, assignment_slug);


--
-- Name: idx_assignment_field_submission_submitter_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_field_submission_submitter_fk ON data.assignment_field_submission USING btree (submitter_user_id);


--
-- Name: idx_assignment_grade_assignment_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_grade_assignment_fk ON data.assignment_grade USING btree (assignment_slug, points_possible);


--
-- Name: idx_assignment_grade_event_actor_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_grade_event_actor_fk ON data.assignment_grade_event USING btree (created_by_user_id);


--
-- Name: idx_assignment_grade_event_natural_key; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_grade_event_natural_key ON data.assignment_grade_event USING btree (assignment_submission_id, created_at, id);


--
-- Name: idx_assignment_grade_exception_assignment_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_grade_exception_assignment_fk ON data.assignment_grade_exception USING btree (assignment_slug, is_team);


--
-- Name: idx_assignment_grade_exception_team_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_grade_exception_team_fk ON data.assignment_grade_exception USING btree (team_nickname);


--
-- Name: idx_assignment_grade_exception_user_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_grade_exception_user_fk ON data.assignment_grade_exception USING btree (user_id);


--
-- Name: idx_assignment_grade_submission_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_grade_submission_fk ON data.assignment_grade USING btree (assignment_submission_id, assignment_slug);


--
-- Name: idx_assignment_submission_assignment_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_submission_assignment_fk ON data.assignment_submission USING btree (assignment_slug, is_team);


--
-- Name: idx_assignment_submission_participant_user_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_submission_participant_user_fk ON data.assignment_submission_participant USING btree (user_id);


--
-- Name: idx_assignment_submission_submitter_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_submission_submitter_fk ON data.assignment_submission USING btree (submitter_user_id);


--
-- Name: idx_assignment_submission_team_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_submission_team_fk ON data.assignment_submission USING btree (team_nickname);


--
-- Name: idx_assignment_submission_user_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_assignment_submission_user_fk ON data.assignment_submission USING btree (user_id);


--
-- Name: idx_engagement_meeting_slug_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_engagement_meeting_slug_fk ON data.engagement USING btree (meeting_slug);


--
-- Name: idx_grade_event_actor_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_grade_event_actor_fk ON data.grade_event USING btree (created_by_user_id);


--
-- Name: idx_grade_event_natural_key; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_grade_event_natural_key ON data.grade_event USING btree (snapshot_slug, user_id, created_at, id);


--
-- Name: idx_grade_user_id_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_grade_user_id_fk ON data.grade USING btree (user_id);


--
-- Name: idx_mcp_grant_revocation_lookup; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_mcp_grant_revocation_lookup ON data.mcp_grant_revocation USING btree (user_id, client_id, revoked_at DESC);


--
-- Name: idx_mcp_jwt_mint_event_caller_window; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_mcp_jwt_mint_event_caller_window ON data.mcp_jwt_mint_event USING btree (caller_app_name, created_at, user_id);


--
-- Name: idx_mcp_jwt_mint_event_user_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_mcp_jwt_mint_event_user_fk ON data.mcp_jwt_mint_event USING btree (user_id);


--
-- Name: idx_quiz_grade_event_actor_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_quiz_grade_event_actor_fk ON data.quiz_grade_event USING btree (created_by_user_id);


--
-- Name: idx_quiz_grade_event_natural_key; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_quiz_grade_event_natural_key ON data.quiz_grade_event USING btree (quiz_id, user_id, created_at, id);


--
-- Name: idx_quiz_grade_exception_user_id_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_quiz_grade_exception_user_id_fk ON data.quiz_grade_exception USING btree (user_id);


--
-- Name: idx_quiz_grade_quiz_points_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_quiz_grade_quiz_points_fk ON data.quiz_grade USING btree (quiz_id, points_possible);


--
-- Name: idx_quiz_grade_user_id_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_quiz_grade_user_id_fk ON data.quiz_grade USING btree (user_id);


--
-- Name: idx_quiz_submission_user_id_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_quiz_submission_user_id_fk ON data.quiz_submission USING btree (user_id);


--
-- Name: idx_user_secret_team_nickname_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_user_secret_team_nickname_fk ON data.user_secret USING btree (team_nickname);


--
-- Name: idx_user_secret_user_id_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_user_secret_user_id_fk ON data.user_secret USING btree (user_id);


--
-- Name: idx_user_team_nickname_fk; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE INDEX idx_user_team_nickname_fk ON data."user" USING btree (team_nickname);


--
-- Name: secret_unique_slug_team; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE UNIQUE INDEX secret_unique_slug_team ON data.user_secret USING btree (team_nickname, slug) WHERE (user_id IS NULL);


--
-- Name: secret_unique_slug_user; Type: INDEX; Schema: data; Owner: cluster_admin
--

CREATE UNIQUE INDEX secret_unique_slug_user ON data.user_secret USING btree (user_id, slug) WHERE (team_nickname IS NULL);


--
-- Name: mcp_grant_revocation mcp_grant_revocation_no_update; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER mcp_grant_revocation_no_update BEFORE DELETE OR UPDATE ON data.mcp_grant_revocation FOR EACH ROW EXECUTE FUNCTION data.mcp_grant_revocation_is_append_only();


--
-- Name: artifact tg_artifact_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_artifact_default BEFORE INSERT OR UPDATE ON data.artifact FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: assignment tg_assignment_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_default BEFORE INSERT OR UPDATE ON data.assignment FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: assignment_field tg_assignment_field_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_field_default BEFORE INSERT OR UPDATE ON data.assignment_field FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: assignment_field_submission tg_assignment_field_submission_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_field_submission_default BEFORE INSERT OR UPDATE ON data.assignment_field_submission FOR EACH ROW EXECUTE FUNCTION data.fill_assignment_field_submission_defaults();


--
-- Name: assignment_field_submission_event tg_assignment_field_submission_event_append_only; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_field_submission_event_append_only BEFORE DELETE OR UPDATE ON data.assignment_field_submission_event FOR EACH ROW EXECUTE FUNCTION data.prevent_assignment_field_submission_event_mutation();


--
-- Name: assignment_field_submission tg_assignment_field_submission_event_history; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_field_submission_event_history AFTER INSERT OR DELETE OR UPDATE ON data.assignment_field_submission FOR EACH ROW EXECUTE FUNCTION data.record_assignment_field_submission_event();


--
-- Name: assignment_grade tg_assignment_grade_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_grade_default BEFORE INSERT OR UPDATE ON data.assignment_grade FOR EACH ROW EXECUTE FUNCTION data.fill_assignment_grade_defaults();


--
-- Name: assignment_grade_event tg_assignment_grade_event_append_only; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_grade_event_append_only BEFORE DELETE OR UPDATE ON data.assignment_grade_event FOR EACH ROW EXECUTE FUNCTION data.prevent_grade_event_mutation();


--
-- Name: assignment_grade tg_assignment_grade_event_history; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_grade_event_history AFTER INSERT OR DELETE OR UPDATE ON data.assignment_grade FOR EACH ROW EXECUTE FUNCTION data.record_assignment_grade_event();


--
-- Name: assignment_grade_exception tg_assignment_grade_exception_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_grade_exception_default BEFORE INSERT OR UPDATE ON data.assignment_grade_exception FOR EACH ROW EXECUTE FUNCTION data.fill_assignment_grade_exception_defaults();


--
-- Name: assignment_submission tg_assignment_submission_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_submission_default BEFORE INSERT OR UPDATE ON data.assignment_submission FOR EACH ROW EXECUTE FUNCTION data.fill_assignment_submission_defaults();


--
-- Name: assignment_submission tg_assignment_submission_participants; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_assignment_submission_participants AFTER INSERT ON data.assignment_submission FOR EACH ROW EXECUTE FUNCTION data.refresh_assignment_submission_participants();


--
-- Name: engagement tg_engagement_update_timestamps; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_engagement_update_timestamps BEFORE INSERT OR UPDATE ON data.engagement FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: grade tg_grade_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_grade_default BEFORE INSERT OR UPDATE ON data.grade FOR EACH ROW EXECUTE FUNCTION data.fill_grade_defaults();


--
-- Name: grade_event tg_grade_event_append_only; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_grade_event_append_only BEFORE DELETE OR UPDATE ON data.grade_event FOR EACH ROW EXECUTE FUNCTION data.prevent_grade_event_mutation();


--
-- Name: grade tg_grade_event_history; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_grade_event_history AFTER INSERT OR DELETE OR UPDATE ON data.grade FOR EACH ROW EXECUTE FUNCTION data.record_grade_event();


--
-- Name: grade_snapshot tg_grade_snapshot_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_grade_snapshot_default BEFORE INSERT OR UPDATE ON data.grade_snapshot FOR EACH ROW EXECUTE FUNCTION data.fill_grade_snapshot_defaults();


--
-- Name: mcp_jwt_mint_event tg_mcp_jwt_mint_event_append_only; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_mcp_jwt_mint_event_append_only BEFORE DELETE OR UPDATE ON data.mcp_jwt_mint_event FOR EACH ROW EXECUTE FUNCTION data.prevent_mcp_jwt_mint_event_mutation();


--
-- Name: meeting tg_meeting_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_meeting_default BEFORE INSERT OR UPDATE ON data.meeting FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: quiz tg_quiz_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_quiz_default BEFORE INSERT OR UPDATE ON data.quiz FOR EACH ROW EXECUTE FUNCTION data.quiz_set_defaults();


--
-- Name: quiz_grade tg_quiz_grade_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_quiz_grade_default BEFORE INSERT OR UPDATE ON data.quiz_grade FOR EACH ROW EXECUTE FUNCTION data.fill_quiz_grade_defaults();


--
-- Name: quiz_grade_event tg_quiz_grade_event_append_only; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_quiz_grade_event_append_only BEFORE DELETE OR UPDATE ON data.quiz_grade_event FOR EACH ROW EXECUTE FUNCTION data.prevent_grade_event_mutation();


--
-- Name: quiz_grade tg_quiz_grade_event_history; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_quiz_grade_event_history AFTER INSERT OR DELETE OR UPDATE ON data.quiz_grade FOR EACH ROW EXECUTE FUNCTION data.record_quiz_grade_event();


--
-- Name: quiz_grade_exception tg_quiz_grade_exception_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_quiz_grade_exception_default BEFORE INSERT OR UPDATE ON data.quiz_grade_exception FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: quiz_submission tg_quiz_submission_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_quiz_submission_default BEFORE INSERT OR UPDATE ON data.quiz_submission FOR EACH ROW EXECUTE FUNCTION data.fill_quiz_submission_defaults();


--
-- Name: team tg_team_update_timestamps; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_team_update_timestamps BEFORE INSERT OR UPDATE ON data.team FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: ui_element tg_ui_element_update_timestamps; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_ui_element_update_timestamps BEFORE INSERT OR UPDATE ON data.ui_element FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: user_secret tg_user_secret_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_user_secret_default BEFORE INSERT OR UPDATE ON data.user_secret FOR EACH ROW EXECUTE FUNCTION data.fill_user_secret_defaults();


--
-- Name: user tg_user_student_engagement_rows; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_user_student_engagement_rows AFTER INSERT OR UPDATE OF role ON data."user" FOR EACH ROW EXECUTE FUNCTION data.ensure_student_engagement_rows();


--
-- Name: user tg_users_default; Type: TRIGGER; Schema: data; Owner: cluster_admin
--

CREATE TRIGGER tg_users_default BEFORE INSERT OR UPDATE ON data."user" FOR EACH ROW EXECUTE FUNCTION data.clean_user_fields();


--
-- Name: artifact artifact_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.artifact
    ADD CONSTRAINT artifact_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: artifact artifact_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.artifact
    ADD CONSTRAINT artifact_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assignment_field assignment_field_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_field
    ADD CONSTRAINT assignment_field_assignment_slug_fkey FOREIGN KEY (assignment_slug) REFERENCES data.assignment(slug) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_assignment_field_slug_assignme_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_assignment_field_slug_assignme_fkey FOREIGN KEY (assignment_field_slug, assignment_slug, assignment_field_is_url, assignment_field_pattern) REFERENCES data.assignment_field(slug, assignment_slug, is_url, pattern) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_assignment_submission_id_assig_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_assignment_submission_id_assig_fkey FOREIGN KEY (assignment_submission_id, assignment_slug) REFERENCES data.assignment_submission(id, assignment_slug) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_submitter_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_submitter_user_id_fkey FOREIGN KEY (submitter_user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_grade assignment_grade_assignment_slug_points_possible_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_grade
    ADD CONSTRAINT assignment_grade_assignment_slug_points_possible_fkey FOREIGN KEY (assignment_slug, points_possible) REFERENCES data.assignment(slug, points_possible) ON UPDATE CASCADE;


--
-- Name: assignment_grade assignment_grade_assignment_submission_id_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_grade
    ADD CONSTRAINT assignment_grade_assignment_submission_id_assignment_slug_fkey FOREIGN KEY (assignment_submission_id, assignment_slug) REFERENCES data.assignment_submission(id, assignment_slug) ON UPDATE CASCADE;


--
-- Name: assignment_grade_exception assignment_grade_exception_assignment_slug_is_team_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_assignment_slug_is_team_fkey FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment(slug, is_team) ON UPDATE CASCADE;


--
-- Name: assignment_grade_exception assignment_grade_exception_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: assignment_grade_exception assignment_grade_exception_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_assignment_slug_is_team_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_assignment_slug_is_team_fkey FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment(slug, is_team) ON UPDATE CASCADE;


--
-- Name: assignment_submission_participant assignment_submission_participant_assignment_submission_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_submission_participant
    ADD CONSTRAINT assignment_submission_participant_assignment_submission_id_fkey FOREIGN KEY (assignment_submission_id) REFERENCES data.assignment_submission(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assignment_submission_participant assignment_submission_participant_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_submission_participant
    ADD CONSTRAINT assignment_submission_participant_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_submitter_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_submitter_user_id_fkey FOREIGN KEY (submitter_user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: engagement engagement_meeting_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.engagement
    ADD CONSTRAINT engagement_meeting_slug_fkey FOREIGN KEY (meeting_slug) REFERENCES data.meeting(slug) ON UPDATE CASCADE;


--
-- Name: engagement engagement_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.engagement
    ADD CONSTRAINT engagement_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: grade grade_snapshot_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.grade
    ADD CONSTRAINT grade_snapshot_slug_fkey FOREIGN KEY (snapshot_slug) REFERENCES data.grade_snapshot(slug) ON UPDATE CASCADE;


--
-- Name: grade grade_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.grade
    ADD CONSTRAINT grade_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: quiz_grade_exception quiz_grade_exception_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE;


--
-- Name: quiz_grade_exception quiz_grade_exception_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: quiz_grade quiz_grade_quiz_id_points_possible_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_quiz_id_points_possible_fkey FOREIGN KEY (quiz_id, points_possible) REFERENCES data.quiz(id, points_possible) ON UPDATE CASCADE;


--
-- Name: quiz_grade quiz_grade_quiz_id_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_quiz_id_user_id_fkey FOREIGN KEY (quiz_id, user_id) REFERENCES data.quiz_submission(quiz_id, user_id) ON UPDATE CASCADE;


--
-- Name: quiz_grade quiz_grade_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: quiz quiz_meeting_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_meeting_slug_fkey FOREIGN KEY (meeting_slug) REFERENCES data.meeting(slug) ON UPDATE CASCADE;


--
-- Name: quiz_submission quiz_submission_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_submission
    ADD CONSTRAINT quiz_submission_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE;


--
-- Name: quiz_submission quiz_submission_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.quiz_submission
    ADD CONSTRAINT quiz_submission_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: user_secret user_secret_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.user_secret
    ADD CONSTRAINT user_secret_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: user_secret user_secret_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data.user_secret
    ADD CONSTRAINT user_secret_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: user user_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: cluster_admin
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: artifact; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.artifact ENABLE ROW LEVEL SECURITY;

--
-- Name: artifact artifact_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY artifact_access_policy ON data.artifact TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND is_user_visible AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_field_submission; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_field_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_field_submission assignment_field_submission_delete_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY assignment_field_submission_delete_policy ON data.assignment_field_submission FOR DELETE TO api USING ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_field_submission_event; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_field_submission_event ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_field_submission_event assignment_field_submission_event_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY assignment_field_submission_event_access_policy ON data.assignment_field_submission_event TO api USING ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_field_submission assignment_field_submission_insert_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY assignment_field_submission_insert_policy ON data.assignment_field_submission FOR INSERT TO api WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND (submitter_user_id = request.user_id()) AND data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id))));


--
-- Name: assignment_field_submission assignment_field_submission_select_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY assignment_field_submission_select_policy ON data.assignment_field_submission FOR SELECT TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND ((submitter_user_id = request.user_id()) OR (EXISTS ( SELECT ass_sub.id
   FROM api.assignment_submissions ass_sub
  WHERE (ass_sub.id = assignment_field_submission.assignment_submission_id))) OR data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id))) OR (request.user_role() = 'faculty'::text)));


--
-- Name: assignment_field_submission assignment_field_submission_update_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY assignment_field_submission_update_policy ON data.assignment_field_submission FOR UPDATE TO api USING (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND ((submitter_user_id = request.user_id()) OR data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id))))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND (submitter_user_id = request.user_id()) AND data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id))));


--
-- Name: assignment_grade; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_grade ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_grade assignment_grade_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY assignment_grade_access_policy ON data.assignment_grade TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (EXISTS ( SELECT ass_sub.id
   FROM api.assignment_submissions ass_sub
  WHERE (assignment_grade.assignment_submission_id = ass_sub.id)))) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_grade_event; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_grade_event ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_grade_event assignment_grade_event_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY assignment_grade_event_access_policy ON data.assignment_grade_event TO api USING ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_grade_exception; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_grade_exception ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_grade_exception assignment_grade_exception_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY assignment_grade_exception_access_policy ON data.assignment_grade_exception TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND (u.team_nickname = assignment_grade_exception.team_nickname))))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_submission; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.assignment_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_submission assignment_submission_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY assignment_submission_access_policy ON data.assignment_submission TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (((request.user_id() = submitter_user_id) AND (NOT (EXISTS ( SELECT 1
   FROM data.assignment_submission_participant p
  WHERE (p.assignment_submission_id = assignment_submission.id))))) OR (EXISTS ( SELECT p.user_id
   FROM data.assignment_submission_participant p
  WHERE ((p.assignment_submission_id = assignment_submission.id) AND (p.user_id = request.user_id())))))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND (EXISTS ( SELECT a.slug
   FROM ((api.assignments a
     LEFT JOIN api.assignment_grade_exceptions e ON ((a.slug = e.assignment_slug)))
     LEFT JOIN api.users u ON (((e.user_id = u.id) OR (e.team_nickname = u.team_nickname))))
  WHERE ((a.slug = assignment_submission.assignment_slug) AND (a.is_open OR ((e.closed_at > CURRENT_TIMESTAMP) AND (a.is_draft = false) AND ((e.user_id = assignment_submission.user_id) OR (e.team_nickname = assignment_submission.team_nickname))))))) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id
   FROM data."user" u
  WHERE ((u.id = request.user_id()) AND (u.team_nickname = assignment_submission.team_nickname)))))))));


--
-- Name: engagement; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.engagement ENABLE ROW LEVEL SECURITY;

--
-- Name: engagement engagement_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY engagement_access_policy ON data.engagement TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = ANY ('{faculty,ta}'::text[]))));


--
-- Name: grade; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.grade ENABLE ROW LEVEL SECURITY;

--
-- Name: grade grade_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY grade_access_policy ON data.grade TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: grade_event; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.grade_event ENABLE ROW LEVEL SECURITY;

--
-- Name: grade_event grade_event_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY grade_event_access_policy ON data.grade_event TO api USING ((request.user_role() = 'faculty'::text));


--
-- Name: mcp_grant_revocation; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.mcp_grant_revocation ENABLE ROW LEVEL SECURITY;

--
-- Name: mcp_grant_revocation mcp_grant_revocation_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY mcp_grant_revocation_access_policy ON data.mcp_grant_revocation TO api USING (((request.user_role() = 'faculty'::text) OR (request.user_id() = user_id) OR ((request.user_role() = 'app'::text) AND (request.app_name() = 'authapp'::text)))) WITH CHECK ((((request.user_role() = 'app'::text) AND (request.app_name() = 'authapp'::text)) OR (request.user_id() = user_id) OR (request.user_role() = 'faculty'::text)));


--
-- Name: mcp_jwt_mint_event; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.mcp_jwt_mint_event ENABLE ROW LEVEL SECURITY;

--
-- Name: mcp_jwt_mint_event mcp_jwt_mint_event_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY mcp_jwt_mint_event_access_policy ON data.mcp_jwt_mint_event TO api USING ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_grade; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.quiz_grade ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_grade quiz_grade_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY quiz_grade_access_policy ON data.quiz_grade TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_grade_event; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.quiz_grade_event ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_grade_event quiz_grade_event_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY quiz_grade_event_access_policy ON data.quiz_grade_event TO api USING ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_grade_exception; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.quiz_grade_exception ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_grade_exception quiz_grade_exception_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY quiz_grade_exception_access_policy ON data.quiz_grade_exception TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_submission; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.quiz_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_submission quiz_submission_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY quiz_submission_access_policy ON data.quiz_submission TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: team; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.team ENABLE ROW LEVEL SECURITY;

--
-- Name: team team_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY team_access_policy ON data.team TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (nickname = ( SELECT users.team_nickname
   FROM api.users
  WHERE (users.id = request.user_id())))) OR (request.user_role() = 'faculty'::text)));


--
-- Name: user; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data."user" ENABLE ROW LEVEL SECURITY;

--
-- Name: user user_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY user_access_policy ON data."user" TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = id)) OR (request.user_role() = ANY ('{faculty,ta}'::text[])) OR ((request.user_role() = 'app'::text) AND (request.app_name() = 'authapp'::text))));


--
-- Name: user_secret; Type: ROW SECURITY; Schema: data; Owner: cluster_admin
--

ALTER TABLE data.user_secret ENABLE ROW LEVEL SECURITY;

--
-- Name: user_secret user_secret_access_policy; Type: POLICY; Schema: data; Owner: cluster_admin
--

CREATE POLICY user_secret_access_policy ON data.user_secret TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND is_user_visible AND ((request.user_id() = user_id) OR (EXISTS ( SELECT u.id
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND (u.team_nickname = user_secret.team_nickname)))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: SCHEMA api; Type: ACL; Schema: -; Owner: cluster_admin
--

GRANT USAGE ON SCHEMA api TO anonymous;
GRANT USAGE ON SCHEMA api TO student;
GRANT USAGE ON SCHEMA api TO ta;
GRANT USAGE ON SCHEMA api TO faculty;
GRANT USAGE ON SCHEMA api TO app;


--
-- Name: SCHEMA data; Type: ACL; Schema: -; Owner: cluster_admin
--

GRANT USAGE ON SCHEMA data TO ta;
GRANT USAGE ON SCHEMA data TO faculty;


--
-- Name: SCHEMA request; Type: ACL; Schema: -; Owner: cluster_admin
--

GRANT USAGE ON SCHEMA request TO PUBLIC;


--
-- Name: FUNCTION check_request_jwt(); Type: ACL; Schema: api; Owner: cluster_admin
--

REVOKE ALL ON FUNCTION api.check_request_jwt() FROM PUBLIC;
GRANT ALL ON FUNCTION api.check_request_jwt() TO anonymous;
GRANT ALL ON FUNCTION api.check_request_jwt() TO student;
GRANT ALL ON FUNCTION api.check_request_jwt() TO ta;
GRANT ALL ON FUNCTION api.check_request_jwt() TO faculty;
GRANT ALL ON FUNCTION api.check_request_jwt() TO app;


--
-- Name: FUNCTION sign_jwt(user_id integer, role data.user_role); Type: ACL; Schema: auth; Owner: cluster_admin
--

REVOKE ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) FROM PUBLIC;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO api;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO student;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO ta;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO faculty;


--
-- Name: TABLE "user"; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data."user" TO api;


--
-- Name: TABLE user_jwts; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.user_jwts TO student;
GRANT SELECT ON TABLE api.user_jwts TO ta;
GRANT SELECT ON TABLE api.user_jwts TO faculty;


--
-- Name: FUNCTION issue_user_jwt(requested_netid text); Type: ACL; Schema: api; Owner: api
--

REVOKE ALL ON FUNCTION api.issue_user_jwt(requested_netid text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.issue_user_jwt(requested_netid text) TO app;


--
-- Name: FUNCTION issue_user_jwt_for_mcp(p_netid text, p_scopes text[], p_external jsonb); Type: ACL; Schema: api; Owner: cluster_admin
--

REVOKE ALL ON FUNCTION api.issue_user_jwt_for_mcp(p_netid text, p_scopes text[], p_external jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION api.issue_user_jwt_for_mcp(p_netid text, p_scopes text[], p_external jsonb) TO app;


--
-- Name: FUNCTION record_mcp_grant_revocation(netid text, client_id text, client_name text, scopes text); Type: ACL; Schema: api; Owner: cluster_admin
--

REVOKE ALL ON FUNCTION api.record_mcp_grant_revocation(netid text, client_id text, client_name text, scopes text) FROM PUBLIC;
GRANT ALL ON FUNCTION api.record_mcp_grant_revocation(netid text, client_id text, client_name text, scopes text) TO app;


--
-- Name: FUNCTION sync_assignments(p_assignments jsonb, p_delete_missing boolean, p_dry_run boolean); Type: ACL; Schema: api; Owner: cluster_admin
--

REVOKE ALL ON FUNCTION api.sync_assignments(p_assignments jsonb, p_delete_missing boolean, p_dry_run boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_assignments(p_assignments jsonb, p_delete_missing boolean, p_dry_run boolean) TO faculty;


--
-- Name: FUNCTION sync_meetings(p_meetings jsonb); Type: ACL; Schema: api; Owner: cluster_admin
--

REVOKE ALL ON FUNCTION api.sync_meetings(p_meetings jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_meetings(p_meetings jsonb) TO faculty;


--
-- Name: FUNCTION sign_mcp_user_jwt(user_id integer, role data.user_role, netid text, scopes text, jti text); Type: ACL; Schema: auth; Owner: cluster_admin
--

REVOKE ALL ON FUNCTION auth.sign_mcp_user_jwt(user_id integer, role data.user_role, netid text, scopes text, jti text) FROM PUBLIC;


--
-- Name: TABLE artifact; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.artifact TO api;


--
-- Name: TABLE artifacts; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.artifacts TO student;
GRANT SELECT ON TABLE api.artifacts TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.artifacts TO faculty;


--
-- Name: TABLE assignment_field_submission_event; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT ON TABLE data.assignment_field_submission_event TO api;


--
-- Name: TABLE assignment_field_submission_events; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_field_submission_events TO faculty;


--
-- Name: TABLE assignment_field_submission; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_field_submission TO api;


--
-- Name: TABLE assignment_field_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,UPDATE ON TABLE api.assignment_field_submissions TO student;
GRANT SELECT,INSERT,UPDATE ON TABLE api.assignment_field_submissions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_field_submissions TO faculty;


--
-- Name: TABLE assignment; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment TO api;


--
-- Name: TABLE assignment_field; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_field TO api;


--
-- Name: TABLE assignment_fields; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_fields TO student;
GRANT SELECT ON TABLE api.assignment_fields TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_fields TO faculty;


--
-- Name: TABLE assignment_grade; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_grade TO api;


--
-- Name: TABLE assignment_submission; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_submission TO api;


--
-- Name: TABLE assignment_submission_participant; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_submission_participant TO api;


--
-- Name: TABLE assignment_grade_distributions; Type: ACL; Schema: api; Owner: cluster_admin
--

GRANT SELECT ON TABLE api.assignment_grade_distributions TO student;
GRANT SELECT ON TABLE api.assignment_grade_distributions TO ta;
GRANT SELECT ON TABLE api.assignment_grade_distributions TO faculty;


--
-- Name: TABLE assignment_grade_event; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT ON TABLE data.assignment_grade_event TO api;


--
-- Name: TABLE assignment_grade_events; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_grade_events TO faculty;


--
-- Name: TABLE assignment_grade_exception; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_grade_exception TO api;


--
-- Name: TABLE assignment_grade_exceptions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_grade_exceptions TO student;
GRANT SELECT ON TABLE api.assignment_grade_exceptions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_grade_exceptions TO faculty;


--
-- Name: TABLE assignment_grades; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_grades TO student;
GRANT SELECT ON TABLE api.assignment_grades TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_grades TO faculty;


--
-- Name: TABLE assignment_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,DELETE ON TABLE api.assignment_submissions TO student;
GRANT SELECT,INSERT,DELETE ON TABLE api.assignment_submissions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_submissions TO faculty;


--
-- Name: TABLE assignments; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignments TO student;
GRANT SELECT ON TABLE api.assignments TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignments TO faculty;


--
-- Name: TABLE engagement; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.engagement TO api;


--
-- Name: TABLE engagements; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.engagements TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.engagements TO faculty;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.engagements TO ta;


--
-- Name: TABLE grade_event; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT ON TABLE data.grade_event TO api;


--
-- Name: TABLE grade_events; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.grade_events TO faculty;


--
-- Name: TABLE grade; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.grade TO api;


--
-- Name: TABLE grade_snapshot_distributions; Type: ACL; Schema: api; Owner: cluster_admin
--

GRANT SELECT ON TABLE api.grade_snapshot_distributions TO student;
GRANT SELECT ON TABLE api.grade_snapshot_distributions TO ta;
GRANT SELECT ON TABLE api.grade_snapshot_distributions TO faculty;


--
-- Name: TABLE grade_snapshot; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.grade_snapshot TO api;


--
-- Name: TABLE grade_snapshots; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.grade_snapshots TO student;
GRANT SELECT ON TABLE api.grade_snapshots TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.grade_snapshots TO faculty;


--
-- Name: TABLE grades; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.grades TO student;
GRANT SELECT ON TABLE api.grades TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.grades TO faculty;


--
-- Name: TABLE mcp_grant_revocation; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT ON TABLE data.mcp_grant_revocation TO api;


--
-- Name: TABLE mcp_grant_revocations; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.mcp_grant_revocations TO student;
GRANT SELECT ON TABLE api.mcp_grant_revocations TO ta;
GRANT SELECT ON TABLE api.mcp_grant_revocations TO faculty;
GRANT SELECT,INSERT ON TABLE api.mcp_grant_revocations TO app;


--
-- Name: TABLE mcp_jwt_mint_event; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT ON TABLE data.mcp_jwt_mint_event TO api;


--
-- Name: TABLE mcp_jwt_mint_anomalies; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.mcp_jwt_mint_anomalies TO faculty;


--
-- Name: TABLE mcp_jwt_mint_events; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.mcp_jwt_mint_events TO faculty;


--
-- Name: TABLE meeting; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.meeting TO api;


--
-- Name: TABLE meetings; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.meetings TO student;
GRANT SELECT ON TABLE api.meetings TO ta;
GRANT SELECT ON TABLE api.meetings TO anonymous;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.meetings TO faculty;


--
-- Name: TABLE platform_version; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.platform_version TO anonymous;
GRANT SELECT ON TABLE api.platform_version TO student;
GRANT SELECT ON TABLE api.platform_version TO ta;
GRANT SELECT ON TABLE api.platform_version TO faculty;
GRANT SELECT ON TABLE api.platform_version TO app;


--
-- Name: TABLE quiz_grade; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_grade TO api;


--
-- Name: TABLE quiz_grade_distributions; Type: ACL; Schema: api; Owner: cluster_admin
--

GRANT SELECT ON TABLE api.quiz_grade_distributions TO student;
GRANT SELECT ON TABLE api.quiz_grade_distributions TO ta;
GRANT SELECT ON TABLE api.quiz_grade_distributions TO faculty;


--
-- Name: TABLE quiz_grade_event; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT ON TABLE data.quiz_grade_event TO api;


--
-- Name: TABLE quiz_grade_events; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_grade_events TO faculty;


--
-- Name: TABLE quiz_grade_exception; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_grade_exception TO api;


--
-- Name: TABLE quiz_grade_exceptions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_grade_exceptions TO student;
GRANT SELECT ON TABLE api.quiz_grade_exceptions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_grade_exceptions TO faculty;


--
-- Name: TABLE quiz_grades; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_grades TO student;
GRANT SELECT ON TABLE api.quiz_grades TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_grades TO faculty;


--
-- Name: TABLE quiz_submission; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_submission TO api;


--
-- Name: TABLE quiz_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_submissions TO student;
GRANT SELECT ON TABLE api.quiz_submissions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_submissions TO faculty;


--
-- Name: TABLE quiz; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz TO api;


--
-- Name: TABLE quizzes; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quizzes TO student;
GRANT SELECT ON TABLE api.quizzes TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quizzes TO faculty;


--
-- Name: TABLE team; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.team TO api;


--
-- Name: TABLE teams; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.teams TO student;
GRANT SELECT ON TABLE api.teams TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.teams TO faculty;


--
-- Name: TABLE ui_element; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.ui_element TO api;


--
-- Name: TABLE ui_elements; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.ui_elements TO student;
GRANT SELECT ON TABLE api.ui_elements TO ta;
GRANT SELECT ON TABLE api.ui_elements TO anonymous;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.ui_elements TO faculty;


--
-- Name: TABLE user_secret; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.user_secret TO api;


--
-- Name: TABLE user_secrets; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.user_secrets TO student;
GRANT SELECT ON TABLE api.user_secrets TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.user_secrets TO faculty;


--
-- Name: TABLE users; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.users TO student;
GRANT SELECT ON TABLE api.users TO ta;
GRANT SELECT ON TABLE api.users TO app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.users TO faculty;


--
-- Name: SEQUENCE mcp_grant_revocation_id_seq; Type: ACL; Schema: data; Owner: cluster_admin
--

GRANT SELECT,USAGE ON SEQUENCE data.mcp_grant_revocation_id_seq TO api;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: -; Owner: api
--

ALTER DEFAULT PRIVILEGES FOR ROLE api REVOKE ALL ON FUNCTIONS FROM PUBLIC;


--
-- PostgreSQL database dump complete
--



-- Runtime configuration is deliberately separate from this immutable schema.
INSERT INTO settings.secrets (key, value) VALUES
  ('jwt_lifetime', '3600'),
  ('jwt_issuer', 'yelukerest'),
  ('jwt_audience', 'yelukerest-postgrest'),
  ('jwt_mcp_audience', 'yelukerest-mcp'),
  ('auth.default-role', 'anonymous'),
  ('auth.data-schema', 'data'),
  ('auth.api-schema', 'api');
