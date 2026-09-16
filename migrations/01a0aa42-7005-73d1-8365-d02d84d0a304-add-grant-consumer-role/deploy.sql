-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.
-- Data grants for consuming apps, step 2 of 3: the credential and the role
-- that can do nothing but present it (issue #385, ADR 0005).
--
-- A grant (01a0aa3b-add-api-grants) needs a credential a consumer can send,
-- and a database role for PostgREST to switch into that can reach exactly one
-- function. Every existing role is a person or a broad service identity;
-- neither fits "may call one function, for one grant".
--
-- The credential is a JWT the platform signs with role grant_consumer and
-- sub grant:<id>. It is returned once by api.create_api_grant and never
-- stored; the permission stays in the database, so revoking the row stops the
-- token. The role holds USAGE on api and EXECUTE on two functions -- the reader
-- and the pre-request hook -- and no relation privilege at all, so every URL
-- but /rpc/granted_submissions fails on privileges before any policy runs. The
-- hook then confines it further: GET and HEAD, on that path, with every claim
-- present and well formed.
--
-- The reader itself is a stub here that validates the credential and the live
-- grant and then refuses; step 3 fills it in.
-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
-- Both roles are provisioned by bin/provision-db.sh, not here: roles are
-- cluster-wide while migrations are per-database, and yelukerest_migrator is
-- deliberately NOCREATEROLE. The same split as authapp
-- (01a05285-add-authapp-session-store). Failing here rather than skipping the
-- grants: a deploy that quietly produced a reader nobody can call would
-- surface as a 401 in some app, hours later and nowhere near the cause.
--
-- Existence is not enough. The grants below are only as narrow as the roles
-- they land on: a grant_consumer that can log in or bypass RLS, or a
-- grant_reader held by faculty (directly, or through some role faculty is
-- in), would hand out the reader's unrestricted SELECT the moment this
-- commits -- and verify runs after the commit. So the attributes and the
-- membership boundary are asserted here, before any GRANT, and a wrong
-- provision fails the transaction.
DO $$
DECLARE
    missing text;
    offending text;
BEGIN
    SELECT string_agg(r, ', ') INTO missing
    FROM unnest(ARRAY['grant_consumer', 'grant_reader']) r
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'role(s) % do not exist', missing
            USING HINT = 'run bin/provision-db.sh once per cluster before deploying this migration';
    END IF;

    SELECT string_agg(rolname, ', ') INTO offending
    FROM pg_roles
    WHERE rolname IN ('grant_consumer', 'grant_reader')
      AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'role(s) % must be NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB NOREPLICATION', offending
            USING HINT = 'bin/provision-db.sh sets those attributes; re-run it';
    END IF;

    -- Neither role may hold any other role: everything either can do comes
    -- from its own grants below, and `GRANT faculty TO grant_consumer` would
    -- otherwise turn a grant credential into a faculty one.
    SELECT string_agg(member.rolname || ' holds ' || held.rolname, ', ') INTO offending
    FROM pg_auth_members m
    JOIN pg_roles member ON member.oid = m.member
    JOIN pg_roles held ON held.oid = m.roleid
    WHERE member.rolname IN ('grant_consumer', 'grant_reader');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'grant_consumer and grant_reader must be members of no role; found %', offending;
    END IF;

    -- Membership, direct or through another role. grant_reader may be held
    -- by the migrator and nobody else.
    WITH RECURSIVE members AS (
        SELECT m.member FROM pg_auth_members m WHERE m.roleid = 'grant_reader'::regrole
        UNION
        SELECT m.member FROM pg_auth_members m JOIN members ON m.roleid = members.member
    )
    SELECT string_agg(r.rolname, ', ') INTO offending
    FROM members JOIN pg_roles r ON r.oid = members.member
    WHERE r.rolname <> 'yelukerest_migrator';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'grant_reader must be held by yelukerest_migrator and nobody else; found %', offending;
    END IF;

    -- grant_consumer may be held only by the authenticator: a login role
    -- that directly holds anonymous, which is how bin/provision-db.sh
    -- provisions it. And somebody must hold it, or PostgREST cannot switch
    -- into it.
    WITH RECURSIVE members AS (
        SELECT m.member FROM pg_auth_members m WHERE m.roleid = 'grant_consumer'::regrole
        UNION
        SELECT m.member FROM pg_auth_members m JOIN members ON m.roleid = members.member
    )
    SELECT string_agg(r.rolname, ', ') INTO offending
    FROM members JOIN pg_roles r ON r.oid = members.member
    WHERE NOT (
        r.rolcanlogin
        AND EXISTS (SELECT FROM pg_auth_members am WHERE am.member = r.oid AND am.roleid = 'anonymous'::regrole)
    );
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'grant_consumer must be held by the authenticator and nobody else; found %', offending;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_auth_members WHERE roleid = 'grant_consumer'::regrole) THEN
        RAISE EXCEPTION 'no login role holds grant_consumer'
            USING HINT = 'bin/provision-db.sh grants it to the authenticator; re-run it';
    END IF;
END;
$$
;
-- grant_consumer: USAGE on api and nothing else. Its two EXECUTE grants follow
-- the functions below.
GRANT usage ON SCHEMA api TO grant_consumer
;
-- grant_reader owns the reader, so SECURITY DEFINER runs it with these
-- privileges and no more: the grant tables, the submission tables, and the
-- user table for the granted identity attributes. Nothing on grades, secrets,
-- tokens, or anything else in data.
GRANT usage ON SCHEMA api, data TO grant_reader
; GRANT select ON data.api_grant, data.api_grant_assignment, data.api_grant_assignment_field, data.assignment_submission, data.assignment_field_submission, data."user" TO grant_reader
;
-- Three of those tables carry row-level security with policies for `api`
-- only, which would give grant_reader no rows at all. The reader decides what
-- to return from the grant row it loads, so these admit every row to it.
CREATE POLICY api_grant_reader_policy ON data.assignment_submission FOR SELECT TO grant_reader USING (true)
; CREATE POLICY api_grant_reader_policy ON data.assignment_field_submission FOR SELECT TO grant_reader USING (true)
; CREATE POLICY api_grant_reader_policy ON data."user" FOR SELECT TO grant_reader USING (true)
;
-- On default privileges: no api function is executable by PUBLIC today (each
-- migration revokes it), but every function the migrator creates starts out
-- that way, and the bootstrap's default revoke covers only functions `api`
-- creates. That gap cannot be closed per schema -- PostgreSQL applies a
-- per-schema ALTER DEFAULT PRIVILEGES on top of the built-in default, so
-- revoking the built-in PUBLIC execute IN SCHEMA api is a no-op -- and a
-- global revoke would silently break the next data.* helper a CHECK or a
-- policy calls as a student. The guard is instead the enumeration in this
-- migration's verify.sql and in tests/db/yeluke-api-grants.sql: a later
-- function that forgets its REVOKE fails the deploy and the suite.
-- ---------------------------------------------------------------------------
-- Signing
-- ---------------------------------------------------------------------------
-- Alongside auth.sign_jwt: the same pgjwt.sign and jwt_secret path, with the
-- grant's own claims and its expiry rather than the session lifetime. Not
-- executable by PUBLIC, so only the owner of api.create_api_grant -- the
-- migrator, through SECURITY DEFINER -- can sign one.
CREATE FUNCTION auth.sign_grant_jwt(grant_id int, expires_at timestamp with time zone, jti text) RETURNS text VOLATILE SECURITY DEFINER LANGUAGE sql SET search_path TO pg_catalog, auth, settings, pgjwt, pg_temp RETURN pgjwt.sign(json_build_object('iss', settings.get('jwt_issuer'), 'aud', settings.get('jwt_audience'), 'sub', 'grant:' || grant_id::text, 'grant_id', grant_id, 'role', 'grant_consumer', 'iat', extract ('epoch' FROM now())::int, 'nbf', extract ('epoch' FROM now())::int, 'jti', jti, 'exp', extract ('epoch' FROM expires_at)::int), settings.get('jwt_secret'))
; ALTER FUNCTION auth.sign_grant_jwt(int, timestamp with time zone, text) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION auth.sign_grant_jwt(int, timestamp with time zone, text) FROM public
;
-- ---------------------------------------------------------------------------
-- Issuing a grant
-- ---------------------------------------------------------------------------
-- Faculty only, resolved to a current faculty row rather than trusted from
-- the claim. Validation and insert are step 1's function; signing happens in
-- the same transaction, so a signing failure leaves no grant behind. The
-- token is returned exactly once.
CREATE FUNCTION api.create_api_grant(p_name text, p_assignments jsonb, p_expires_at timestamp with time zone = now() + '90 days'::interval) RETURNS TABLE (id int, token text, expires_at timestamp with time zone) SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, api, auth, data, request, public, pg_temp AS $$
DECLARE
    caller_id int;
    new_id int;
    signed_jwt text;
BEGIN
    IF request.user_role() IS DISTINCT FROM 'faculty' THEN
        RAISE insufficient_privilege USING MESSAGE = 'only faculty may create an api grant';
    END IF;
    SELECT u.id INTO caller_id FROM data."user" u WHERE u.id = request.user_id() AND u.role = 'faculty';
    IF caller_id IS NULL THEN
        RAISE insufficient_privilege USING MESSAGE = 'the caller is not a current faculty member';
    END IF;

    new_id := data.create_api_grant_rows(p_name, p_assignments, p_expires_at, caller_id);

    -- pgjwt.sign returns NULL rather than raising when the secret is missing.
    signed_jwt := auth.sign_grant_jwt(new_id, p_expires_at, public.gen_random_uuid()::text);
    IF signed_jwt IS NULL THEN
        RAISE EXCEPTION 'the grant credential could not be signed';
    END IF;

    RETURN QUERY SELECT new_id, signed_jwt, p_expires_at;
END;
$$
; ALTER FUNCTION api.create_api_grant(text, jsonb, timestamp with time zone) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.create_api_grant(text, jsonb, timestamp with time zone) FROM public
; GRANT execute ON FUNCTION api.create_api_grant(text, jsonb, timestamp with time zone) TO faculty
; COMMENT ON FUNCTION api.create_api_grant(text, jsonb, timestamp with time zone) IS 'Create a grant for a consuming app and return its credential exactly once. Faculty only. p_assignments is [{assignment_slug, identity, field_slugs}]; expiry defaults to 90 days and may not exceed 180.'
;
-- ---------------------------------------------------------------------------
-- The reader, as a stub
-- ---------------------------------------------------------------------------
-- The final signature, owned by grant_reader, checking the credential and the
-- live grant exactly as the real reader will, and then refusing. Shipping the
-- shape now lets the role, the hook and the tests land against the real
-- surface; step 3 replaces the body.
CREATE FUNCTION api.granted_submissions(p_assignment_slug text = NULL, p_after_id int = NULL, p_limit int = 200) RETURNS SETOF jsonb STABLE SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, data, request, pg_temp AS $$
DECLARE
    grant_id_text text;
    live_grant data.api_grant%ROWTYPE;
BEGIN
    IF request.user_role() IS DISTINCT FROM 'grant_consumer' THEN
        RAISE insufficient_privilege USING MESSAGE = 'granted_submissions accepts only a grant credential';
    END IF;
    grant_id_text := request.jwt_claim('grant_id');
    IF grant_id_text IS NULL
       OR grant_id_text !~ '^[1-9][0-9]{0,8}$'
       OR request.jwt_claim('sub') IS DISTINCT FROM 'grant:' || grant_id_text THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid grant credential';
    END IF;

    SELECT g.* INTO live_grant FROM data.api_grant g WHERE g.id = grant_id_text::int;
    IF NOT FOUND OR live_grant.revoked_at IS NOT NULL OR live_grant.expires_at <= current_timestamp THEN
        RAISE insufficient_privilege USING MESSAGE = 'this grant has been revoked or has expired';
    END IF;

    RAISE EXCEPTION 'granted_submissions is not yet available' USING ERRCODE = '0A000';
END;
$$
;
-- Handing ownership to grant_reader needs it to hold CREATE on api for the
-- duration of the ALTER and not afterwards: ownership does not depend on it,
-- and a role that can create objects in api is not narrow.
GRANT create ON SCHEMA api TO grant_reader
; ALTER FUNCTION api.granted_submissions(text, int, int) OWNER TO grant_reader
; REVOKE create ON SCHEMA api FROM grant_reader
; REVOKE ALL ON FUNCTION api.granted_submissions(text, int, int) FROM public
; GRANT execute ON FUNCTION api.granted_submissions(text, int, int) TO grant_consumer
; COMMENT ON FUNCTION api.granted_submissions(text, int, int) IS 'Reader for grant credentials. Not yet available: refuses every call until the add-granted-submissions-reader migration.'
;
-- ---------------------------------------------------------------------------
-- The pre-request hook
-- ---------------------------------------------------------------------------
-- Two changes to the function as 01a0481a-bound-student-row-writes left it,
-- both marked below: the grant_consumer branch, and the audience test.
-- The audience test was `IF NOT (...)`: with no aud claim at all every
-- operand is NULL, NOT NULL is NULL, and a NULL condition does not raise --
-- so a token with the issuer right and no audience passed. `IS NOT TRUE`
-- refuses it.
CREATE OR REPLACE FUNCTION api.check_request_jwt() RETURNS void STABLE SECURITY DEFINER LANGUAGE plpgsql SET search_path TO pg_catalog, api, settings, request, pg_temp AS $$
DECLARE
    claims jsonb;
    claim_role text;
    claim_issuer text;
    expected_audience text;
    expected_subject text;
    audience_claim jsonb;
    audience_text text;
    subject_claim text;
    scopes_claim text;
    request_method text;
    request_path text;
    grant_id_text text;
    exp_text text;
BEGIN
    -- A fresh row budget for this request (issue #346).
    PERFORM request.reset_row_bound_counters();

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
    -- Changed (issue #385): IS NOT TRUE, so a missing audience fails closed.
    IF (
        (jsonb_typeof(audience_claim) = 'string' AND audience_claim #>> '{}' = expected_audience)
        OR
        (jsonb_typeof(audience_claim) = 'array' AND audience_claim ? expected_audience)
        OR
        audience_text = expected_audience
    ) IS NOT TRUE THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt audience';
    END IF;

    -- Grant credentials (issue #385, ADR 0005). The role's privileges already
    -- confine it to two functions; this confines the request: a positive
    -- integer grant_id, a numeric exp, and only a read of the one endpoint.
    -- request.method and request.path are what PostgREST sets for every
    -- request, so their absence means this is not a PostgREST request and a
    -- grant credential has no business here.
    IF claim_role = 'grant_consumer' THEN
        grant_id_text := request.jwt_claim('grant_id');
        IF grant_id_text IS NULL OR grant_id_text !~ '^[1-9][0-9]{0,8}$' THEN
            RAISE insufficient_privilege USING MESSAGE = 'invalid grant_id claim';
        END IF;
        exp_text := request.jwt_claim('exp');
        IF exp_text IS NULL
           OR exp_text !~ '^[0-9]{1,18}$'
           OR (claims IS NOT NULL AND jsonb_typeof(claims->'exp') IS DISTINCT FROM 'number') THEN
            RAISE insufficient_privilege USING MESSAGE = 'invalid exp claim';
        END IF;
        request_method := upper(coalesce(current_setting('request.method', true), ''));
        IF request_method NOT IN ('GET', 'HEAD') THEN
            RAISE insufficient_privilege USING MESSAGE = 'a grant credential may only read';
        END IF;
        request_path := coalesce(current_setting('request.path', true), '');
        IF request_path <> '/rpc/granted_submissions' THEN
            RAISE insufficient_privilege USING MESSAGE = 'a grant credential may only call granted_submissions';
        END IF;
    END IF;

    subject_claim := request.jwt_claim('sub');
    IF coalesce(subject_claim, '') = '' THEN
        RAISE insufficient_privilege USING MESSAGE = 'missing jwt subject';
    END IF;

    expected_subject := CASE
        WHEN claim_role = 'app' THEN 'app:' || coalesce(request.app_name(), '')
        WHEN claim_role = 'grant_consumer' THEN 'grant:' || grant_id_text
        ELSE 'user:' || coalesce(request.user_id_as_text(), '')
    END;
    IF subject_claim IS DISTINCT FROM expected_subject THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt subject';
    END IF;

    -- Scope enforcement for scope-carrying tokens (issue #317).
    --
    -- A JWT minted from a personal access token, or by mcpapp, carries a
    -- `scopes` claim. Until now nothing on the PostgREST path looked at it:
    -- mcpapp checked scopes for its own tool calls, but a token exchanged from
    -- a read-only personal access token could still PATCH a submission,
    -- because row-level security asks who you are and never what the token was
    -- allowed to do. Verified before this change: a read-only token PATCHed
    -- assignment_field_submissions and got a 200.
    --
    -- Tokens with no `scopes` claim -- the browser JWT from /auth/jwt, and the
    -- authapp/mcpapp service credentials -- are unaffected and keep the
    -- permissions their role gives them.
    --
    -- The rule matches what mcpapp already enforces for its escape hatch: read
    -- methods are free, everything else needs submissions:write. This also
    -- stops a read-only token calling create_user_api_token to mint itself a
    -- writable one, which would otherwise be a straightforward escalation.
    scopes_claim := request.jwt_claim('scopes');
    IF coalesce(scopes_claim, '') <> '' THEN
        request_method := upper(coalesce(current_setting('request.method', true), ''));
        -- An empty method means this is not a PostgREST request (a direct psql
        -- session, say), so there is nothing to gate.
        IF request_method <> '' AND request_method NOT IN ('GET', 'HEAD', 'OPTIONS') THEN
            IF position(' submissions:write ' in ' ' || scopes_claim || ' ') = 0 THEN
                RAISE insufficient_privilege
                    USING MESSAGE = 'this token is read-only: it lacks the submissions:write scope';
            END IF;
        END IF;
    END IF;
END;
$$
; ALTER FUNCTION api.check_request_jwt() OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.check_request_jwt() FROM public
; GRANT execute ON FUNCTION api.check_request_jwt() TO anonymous, student, ta, faculty, observer, app, grant_consumer
; NOTIFY pgrst, 'reload schema'
