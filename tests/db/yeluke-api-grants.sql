-- Data grants for consuming apps (issues #384-#386, ADR 0005): the immutable
-- permission rows and their lifecycle, the grant_consumer credential, and the
-- reader that returns granted values only.
--
-- Sample data in play: exam-1 is an individual assignment with fields
-- profound, url and fooword; project-update-1 is a team assignment with fields
-- repo-url and update-url; user 3 is the only faculty member.
SELECT *
FROM no_plan()
;
-- ---------------------------------------------------------------
-- Structure and privileges (#384)
-- ---------------------------------------------------------------
SELECT view_owner_is('api', 'api_grants', 'api', 'api.api_grants should be owned by the api role')
; SELECT table_privs_are('api', 'api_grants', 'faculty', ARRAY['SELECT'], 'faculty should only be granted SELECT on api.api_grants')
; SELECT table_privs_are('api', 'api_grants', 'student', ARRAY[]::text[], 'student should not be granted privileges on api.api_grants')
; SELECT table_privs_are('api', 'api_grants', 'ta', ARRAY[]::text[], 'ta should not be granted privileges on api.api_grants')
; SELECT table_privs_are('api', 'api_grants', 'app', ARRAY[]::text[], 'app should not be granted privileges on api.api_grants')
; SELECT function_privs_are('api', 'revoke_api_grant', ARRAY['integer'], 'faculty', ARRAY['EXECUTE'], 'faculty should be granted EXECUTE on api.revoke_api_grant')
; SELECT function_privs_are('api', 'revoke_api_grant', ARRAY['integer'], 'student', ARRAY[]::text[], 'student should not be granted EXECUTE on api.revoke_api_grant')
; SELECT function_privs_are('api', 'revoke_api_grant', ARRAY['integer'], 'app', ARRAY[]::text[], 'app should not be granted EXECUTE on api.revoke_api_grant')
;
-- Nothing on the listing could be a credential: none is stored.
SELECT is_empty(' SELECT column_name FROM information_schema.columns
        WHERE table_schema = ''api'' AND table_name = ''api_grants''
          AND (column_name LIKE ''%token%'' OR column_name LIKE ''%secret%'' OR column_name LIKE ''%jwt%'') ', 'api.api_grants must not carry a credential column')
;
-- ---------------------------------------------------------------
-- Creation: the validated insert (#384)
-- ---------------------------------------------------------------
SELECT
    ok((
        SELECT data.create_api_grant_rows('voting app', '[{"assignment_slug": "exam-1", "identity": ["netid", "name"], "field_slugs": ["url", "profound"]},
                  {"assignment_slug": "project-update-1", "identity": [], "field_slugs": ["repo-url"]}]', current_timestamp + '90 days'::interval, 3) > 0
    ), 'a valid request creates a grant')
; SELECT results_eq('
        SELECT ga.assignment_slug, ga.identity,
               (SELECT array_agg(f.field_slug ORDER BY f.field_slug)
                  FROM data.api_grant_assignment_field f
                 WHERE f.grant_id = ga.grant_id AND f.assignment_slug = ga.assignment_slug)
        FROM data.api_grant_assignment ga
        JOIN data.api_grant g ON g.id = ga.grant_id
        WHERE g.name = ''voting app''
        ORDER BY ga.assignment_slug
    ', ' VALUES (''exam-1''::text, ARRAY[''netid'', ''name'']::text[], ARRAY[''profound'', ''url'']::text[]),
               (''project-update-1''::text, ''{}''::text[], ARRAY[''repo-url'']::text[]) ', 'the permission rows are exactly what was asked for, an empty identity included')
;
-- Invalid input rolls back completely: the first entry is fine, the second
-- names a field that does not exist, and neither row survives.
SELECT throws_ok(' SELECT data.create_api_grant_rows(''half bad'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]},
              {"assignment_slug": "project-update-1", "identity": [], "field_slugs": ["nope"]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'an unknown field in a later entry is refused')
; SELECT is_empty(' SELECT id FROM data.api_grant WHERE name = ''half bad'' ', 'and nothing of that request is kept')
;
-- Each rule of the request shape, refused with the input-error code.
SELECT throws_ok(' SELECT data.create_api_grant_rows(''empty'', ''[]'', current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'at least one assignment is required')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''no fields'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": []}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'at least one field per assignment is required')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''null element'',
            ''[{"assignment_slug": "exam-1", "identity": [null], "field_slugs": ["url"]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'a null identity element is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''null field'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url", null]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'a null field element is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''dup field'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url", "url"]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'a duplicate field is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''dup identity'',
            ''[{"assignment_slug": "exam-1", "identity": ["netid", "netid"], "field_slugs": ["url"]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'a duplicate identity attribute is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''dup assignment'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]},
              {"assignment_slug": "exam-1", "identity": [], "field_slugs": ["profound"]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'an assignment listed twice is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''bad identity'',
            ''[{"assignment_slug": "exam-1", "identity": ["email"], "field_slugs": ["url"]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'an identity attribute outside netid, name, nickname, team_nickname is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''bad key'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"], "scope": "everything"}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'an unknown JSON key is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''missing key'',
            ''[{"assignment_slug": "exam-1", "field_slugs": ["url"]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'a missing identity key is refused rather than defaulted')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''bad assignment'',
            ''[{"assignment_slug": "no-such-assignment", "identity": [], "field_slugs": ["url"]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'an unknown assignment is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''ab'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]}]'',
            current_timestamp + interval ''1 day'', 3) ', '22023', NULL, 'a name shorter than 3 characters is refused')
;
-- Expiry at the boundaries. created_at and current_timestamp agree within a
-- transaction, so exactly 180 days is the last accepted value...
SELECT
    ok((
        SELECT data.create_api_grant_rows('boundary 180', '[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]}]', current_timestamp + '180 days'::interval, 3) > 0
    ), 'an expiry exactly 180 days out is accepted')
;
-- ...and one second more is refused, naming the bound rather than clamping.
SELECT throws_like(' SELECT data.create_api_grant_rows(''boundary over'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]}]'',
            current_timestamp + interval ''180 days 1 second'', 3) ', '%at most 180 days%', 'an expiry past 180 days is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''past'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]}]'',
            current_timestamp - interval ''1 second'', 3) ', '22023', NULL, 'an expiry in the past is refused')
; SELECT throws_ok(' SELECT data.create_api_grant_rows(''no expiry'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]}]'',
            NULL, 3) ', '22023', NULL, 'a null expiry is refused')
;
-- The table is the backstop for rows that arrive another way.
SELECT throws_ok(' INSERT INTO data.api_grant (name, created_by, expires_at)
        VALUES (''backstop'', 3, current_timestamp + interval ''181 days'') ', '23514', NULL, 'the table refuses a lifetime over 180 days however it arrives')
; SELECT throws_ok(' INSERT INTO data.api_grant (name, created_by, expires_at, revoked_at)
        VALUES (''half revoked'', 3, current_timestamp + interval ''1 day'', current_timestamp) ', '23514', NULL, 'the table refuses a revocation time without an actor')
;
-- ---------------------------------------------------------------
-- Immutability (#384)
-- ---------------------------------------------------------------
SELECT throws_ok(' INSERT INTO data.api_grant_assignment_field (grant_id, assignment_slug, field_slug)
        SELECT id, ''exam-1'', ''fooword'' FROM data.api_grant WHERE name = ''voting app'' ', '42501', NULL, 'a field cannot be added to an existing grant')
; SELECT throws_ok(' INSERT INTO data.api_grant_assignment (grant_id, assignment_slug, identity)
        SELECT id, ''team-selection'', ''{}'' FROM data.api_grant WHERE name = ''voting app'' ', '42501', NULL, 'an assignment cannot be added to an existing grant')
; SELECT throws_ok(' UPDATE data.api_grant_assignment SET identity = ARRAY[''nickname'']
        WHERE grant_id = (SELECT id FROM data.api_grant WHERE name = ''voting app'') ', '42501', NULL, 'the identity attributes of a grant cannot be changed')
; SELECT throws_ok(' DELETE FROM data.api_grant_assignment_field
        WHERE grant_id = (SELECT id FROM data.api_grant WHERE name = ''voting app'') ', '42501', NULL, 'a granted field cannot be removed')
; SELECT throws_ok(' UPDATE data.api_grant SET name = ''renamed'' WHERE name = ''voting app'' ', '42501', NULL, 'a grant cannot be renamed')
; SELECT throws_ok(' UPDATE data.api_grant SET expires_at = expires_at + interval ''1 day'' WHERE name = ''voting app'' ', '42501', NULL, 'a grant''s expiry cannot be extended')
;
-- ---------------------------------------------------------------
-- Revocation (#384)
-- ---------------------------------------------------------------
-- A second faculty member, so the second revoke below comes from someone
-- other than the first.
INSERT INTO data."user" (id, netid, name, nickname, role)
VALUES (9001, 'fac2', 'Second Faculty', 'second-faculty', 'faculty')
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT throws_like(' SELECT * FROM api.revoke_api_grant((SELECT id FROM data.api_grant WHERE name = ''voting app'')) ', '%faculty%', 'a student cannot revoke a grant')
;
-- The claim says faculty; the user row says student. The row wins.
SET "request.jwt.claim.role" TO faculty
; SELECT throws_like(' SELECT * FROM api.revoke_api_grant((SELECT id FROM data.api_grant WHERE name = ''voting app'')) ', '%current faculty%', 'a faculty claim on a non-faculty user row cannot revoke a grant')
; SELECT
    "is"((
        SELECT revoked_by
        FROM data.api_grant
        WHERE name = 'voting app'
    ), NULL::int, 'the refused calls changed nothing')
; SET "request.jwt.claim.user_id" TO "3"
; SELECT results_eq(' SELECT revoked_by, revoked_at IS NOT NULL
        FROM api.revoke_api_grant((SELECT id FROM data.api_grant WHERE name = ''voting app'')) ', ' VALUES (3, true) ', 'faculty can revoke a grant, and the result names them')
;
-- Revoking again, as someone else, leaves the first actor and time in place.
SET "request.jwt.claim.user_id" TO "9001"
; SELECT results_eq(' SELECT revoked_by, revoked_at IS NOT NULL
        FROM api.revoke_api_grant((SELECT id FROM data.api_grant WHERE name = ''voting app'')) ', ' VALUES (3, true) ', 'a second revoke succeeds and reports the first actor')
; SELECT is_empty(' SELECT id FROM api.revoke_api_grant(-1) ', 'revoking an unknown grant returns no row')
;
-- ---------------------------------------------------------------
-- A referenced field is pinned, revoked grant or not (#384)
-- ---------------------------------------------------------------
SELECT throws_ok(' UPDATE data.assignment_field SET slug = ''url-renamed''
        WHERE slug = ''url'' AND assignment_slug = ''exam-1'' ', '23503', NULL, 'a field a grant names cannot be renamed')
; SELECT throws_ok(' DELETE FROM data.assignment_field
        WHERE slug = ''url'' AND assignment_slug = ''exam-1'' ', '23503', NULL, 'a field a grant names cannot be dropped')
; SELECT throws_ok(' UPDATE data.assignment SET slug = ''exam-one'' WHERE slug = ''exam-1'' ', '23503', NULL, 'an assignment a grant names cannot be renamed')
;
-- ---------------------------------------------------------------
-- The faculty listing (#384)
-- ---------------------------------------------------------------
SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT results_eq(' SELECT created_by, revoked_by, is_active, permissions
        FROM api.api_grants WHERE name = ''voting app'' ', ' VALUES (3, 3, false,
            ''[{"assignment_slug": "exam-1", "identity": ["netid", "name"], "field_slugs": ["profound", "url"]},
               {"assignment_slug": "project-update-1", "identity": [], "field_slugs": ["repo-url"]}]''::jsonb) ', 'faculty see the grant, its actors, its state and its permissions in request shape')
; SELECT
    "is"((
        SELECT is_active
        FROM api.api_grants
        WHERE name = 'boundary 180'
    ), true, 'an unrevoked, unexpired grant lists as active')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT throws_ok(' SELECT id FROM api.api_grants ', '42501', NULL, 'students cannot read the listing at all')
; RESET role
;
-- ---------------------------------------------------------------
-- The grant_consumer role: what it can reach, effectively (#385)
-- ---------------------------------------------------------------
-- Effective privilege, so PUBLIC grants and default privileges count. These
-- are the enumerations ADR 0005 relies on: a later migration cannot widen the
-- role without one of them failing.
SELECT set_eq('
        SELECT p.proname || ''('' || oidvectortypes(p.proargtypes) || '')''
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = ''api''
          AND has_function_privilege(''grant_consumer'', p.oid, ''EXECUTE'')
    ', ARRAY['check_request_jwt()', 'granted_submissions(text, integer, integer)'], 'grant_consumer can execute exactly the reader and the pre-request hook, across every api function overload')
;
-- Every table privilege PostgreSQL has, every column privilege (a column
-- grant lives in pg_attribute, invisible to the table check), and every
-- sequence privilege: none of them, on anything in api or data.
SELECT is_empty('
        SELECT c.oid::regclass::text || '' '' || priv
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN unnest(ARRAY[''SELECT'', ''INSERT'', ''UPDATE'', ''DELETE'', ''TRUNCATE'', ''REFERENCES'', ''TRIGGER'', ''MAINTAIN'']) priv
        WHERE n.nspname IN (''api'', ''data'')
          AND c.relkind IN (''r'', ''v'', ''m'', ''p'', ''f'')
          AND has_table_privilege(''grant_consumer'', c.oid, priv)
    ', 'grant_consumer holds no table privilege on any relation in api or data')
; SELECT is_empty('
        SELECT c.oid::regclass::text || ''.'' || a.attname || '' '' || priv
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN unnest(ARRAY[''SELECT'', ''INSERT'', ''UPDATE'', ''REFERENCES'']) priv
        WHERE n.nspname IN (''api'', ''data'')
          AND c.relkind IN (''r'', ''v'', ''m'', ''p'', ''f'')
          AND a.attnum > 0 AND NOT a.attisdropped
          AND has_column_privilege(''grant_consumer'', c.oid, a.attnum, priv)
    ', 'grant_consumer holds no column privilege on any column in api or data')
; SELECT is_empty('
        SELECT c.oid::regclass::text || '' '' || priv
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN unnest(ARRAY[''USAGE'', ''SELECT'', ''UPDATE'']) priv
        WHERE n.nspname IN (''api'', ''data'')
          AND c.relkind = ''S''
          AND has_sequence_privilege(''grant_consumer'', c.oid, priv)
    ', 'grant_consumer holds no sequence privilege in api or data')
;
-- grant_reader: SELECT on the six tables the reader needs and nothing else,
-- by the same three enumerations.
SELECT set_eq('
        SELECT n.nspname || ''.'' || c.relname || '' '' || priv
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN unnest(ARRAY[''SELECT'', ''INSERT'', ''UPDATE'', ''DELETE'', ''TRUNCATE'', ''REFERENCES'', ''TRIGGER'', ''MAINTAIN'']) priv
        WHERE n.nspname IN (''api'', ''data'')
          AND c.relkind IN (''r'', ''v'', ''m'', ''p'', ''f'')
          AND has_table_privilege(''grant_reader'', c.oid, priv)
    ', ARRAY['data.user SELECT', 'data.api_grant SELECT', 'data.api_grant_assignment SELECT', 'data.api_grant_assignment_field SELECT', 'data.assignment_submission SELECT', 'data.assignment_field_submission SELECT'], 'grant_reader holds SELECT on exactly the six tables the reader needs and no other table privilege')
; SELECT is_empty('
        SELECT c.oid::regclass::text || ''.'' || a.attname || '' '' || priv
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN unnest(ARRAY[''SELECT'', ''INSERT'', ''UPDATE'', ''REFERENCES'']) priv
        WHERE n.nspname IN (''api'', ''data'')
          AND c.relkind IN (''r'', ''v'', ''m'', ''p'', ''f'')
          AND a.attnum > 0 AND NOT a.attisdropped
          AND has_column_privilege(''grant_reader'', c.oid, a.attnum, priv)
          AND NOT (priv = ''SELECT'' AND c.oid IN (
              ''data."user"''::regclass, ''data.api_grant''::regclass,
              ''data.api_grant_assignment''::regclass, ''data.api_grant_assignment_field''::regclass,
              ''data.assignment_submission''::regclass, ''data.assignment_field_submission''::regclass))
    ', 'grant_reader holds no column privilege beyond that SELECT')
; SELECT is_empty('
        SELECT c.oid::regclass::text || '' '' || priv
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN unnest(ARRAY[''USAGE'', ''SELECT'', ''UPDATE'']) priv
        WHERE n.nspname IN (''api'', ''data'')
          AND c.relkind = ''S''
          AND has_sequence_privilege(''grant_reader'', c.oid, priv)
    ', 'grant_reader holds no sequence privilege in api or data')
; SELECT set_eq('
        SELECT s
        FROM unnest(ARRAY[''api'', ''auth'', ''data'', ''pgjwt'', ''request'', ''settings'', ''public'']) s
        WHERE has_schema_privilege(''grant_consumer'', s, ''USAGE'')
    ', ARRAY['api', 'request', 'public'], 'grant_consumer has USAGE on api and otherwise only on the schemas every role has')
; SELECT is_empty(' SELECT member.rolname FROM pg_auth_members m
        JOIN pg_roles member ON member.oid = m.member
        WHERE member.rolname = ''grant_consumer'' ', 'grant_consumer is a member of no role')
;
-- Who holds each role, directly or through another role: a membership is
-- the one route into the reader that no ACL enumeration above would see.
SELECT set_eq('
        WITH RECURSIVE members AS (
            SELECT m.member FROM pg_auth_members m WHERE m.roleid = ''grant_reader''::regrole
            UNION
            SELECT m.member FROM pg_auth_members m JOIN members ON m.roleid = members.member
        )
        SELECT r.rolname::text FROM members JOIN pg_roles r ON r.oid = members.member
    ', ARRAY['yelukerest_migrator'], 'grant_reader is held by the migrator and nobody else, directly or transitively')
; SELECT set_eq('
        WITH RECURSIVE members AS (
            SELECT m.member FROM pg_auth_members m WHERE m.roleid = ''grant_consumer''::regrole
            UNION
            SELECT m.member FROM pg_auth_members m JOIN members ON m.roleid = members.member
        )
        SELECT r.rolname::text FROM members JOIN pg_roles r ON r.oid = members.member
    ', '
        SELECT r.rolname::text FROM pg_roles r
        WHERE r.rolcanlogin
          AND EXISTS (SELECT FROM pg_auth_members am WHERE am.member = r.oid AND am.roleid = ''anonymous''::regrole)
    ', 'grant_consumer is held by the authenticator and nobody else, directly or transitively')
; SELECT
    "is"((
        SELECT rolcanlogin
        FROM pg_roles
        WHERE rolname = 'grant_consumer'
    ), false, 'grant_consumer cannot log in')
; SELECT
    "is"((
        SELECT pg_get_userbyid(proowner)::text
        FROM pg_proc
        WHERE oid = 'api.granted_submissions(text, int, int)'::regprocedure
    ), 'grant_reader', 'the reader is owned by the narrow grant_reader role')
; SELECT function_privs_are('api', 'create_api_grant', ARRAY['text', 'jsonb', 'timestamp with time zone'], 'faculty', ARRAY['EXECUTE'], 'faculty should be granted EXECUTE on api.create_api_grant')
; SELECT function_privs_are('api', 'create_api_grant', ARRAY['text', 'jsonb', 'timestamp with time zone'], 'student', ARRAY[]::text[], 'student should not be granted EXECUTE on api.create_api_grant')
; SELECT function_privs_are('api', 'create_api_grant', ARRAY['text', 'jsonb', 'timestamp with time zone'], 'grant_consumer', ARRAY[]::text[], 'a grant credential cannot mint another grant')
; SELECT "is"(has_function_privilege('faculty', 'auth.sign_grant_jwt(int, timestamp with time zone, text)', 'EXECUTE'), false, 'faculty cannot sign a grant credential directly')
; SELECT "is"(has_function_privilege('app', 'auth.sign_grant_jwt(int, timestamp with time zone, text)', 'EXECUTE'), false, 'app cannot sign a grant credential directly')
;
-- ---------------------------------------------------------------
-- Issuance (#385)
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION zapadka_test.verify_grant_jwt(jwt text) RETURNS TABLE (header pg_catalog.json, payload pg_catalog.json, valid boolean) STABLE SECURITY DEFINER LANGUAGE sql SET search_path TO pg_catalog, pgjwt, settings, pg_temp BEGIN ATOMIC
    SELECT *
    FROM pgjwt.verify(jwt, settings.get('jwt_secret'))
; END
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; CREATE TEMPORARY TABLE issued AS
    SELECT *
    FROM api.create_api_grant('issued app', '[{"assignment_slug": "exam-1", "identity": ["netid"], "field_slugs": ["url"]}]')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM issued
    ), 1, 'faculty receive exactly one credential per grant')
; SELECT
    ok((
        SELECT (zapadka_test.verify_grant_jwt(token)).valid
        FROM issued
    ), 'the credential verifies against the course jwt_secret')
; SELECT results_eq('
        SELECT payload->>''role'' AS role, payload->>''sub'' AS sub, (payload->>''grant_id'')::int AS grant_id,
               payload->>''iss'' AS iss, payload->>''aud'' AS aud,
               (payload->>''exp'')::bigint = extract(epoch FROM i.expires_at)::bigint AS exp_is_expiry,
               (payload->>''iat'')::bigint <= (payload->>''nbf'')::bigint AS iat_before_nbf,
               length(payload->>''jti'') > 0 AS has_jti
        FROM issued i,
             LATERAL (SELECT (zapadka_test.verify_grant_jwt(i.token)).payload::json AS payload) t
    ', ' SELECT ''grant_consumer''::text AS role, ''grant:'' || id AS sub, id AS grant_id, ''yelukerest''::text AS iss,
               ''yelukerest-postgrest''::text AS aud, true AS exp_is_expiry, true AS iat_before_nbf, true AS has_jti
        FROM issued ', 'the credential carries role, sub, grant_id, iss, aud, an integer exp equal to the grant''s expiry, iat, nbf and a jti')
; SELECT
    ok((
        SELECT
            expires_at > (current_timestamp + '89 days'::interval)
            AND expires_at < (current_timestamp + '91 days'::interval)
        FROM issued
    ), 'the default expiry is 90 days out')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.api_grant
        WHERE name = 'issued app'
    ), 1, 'the grant row exists once the credential is issued')
; SELECT is_empty(' SELECT column_name FROM information_schema.columns
        WHERE table_schema = ''data'' AND table_name LIKE ''api_grant%''
          AND (column_name LIKE ''%token%'' OR column_name LIKE ''%jwt%'' OR column_name LIKE ''%secret%'') ', 'nothing about the credential is stored')
;
-- Invalid input through the wrapper is refused and leaves nothing behind.
SELECT throws_ok(' SELECT * FROM api.create_api_grant(''wrapped bad'', ''[]'') ', '22023', NULL, 'the wrapper refuses what the validated insert refuses')
; SELECT is_empty(' SELECT id FROM data.api_grant WHERE name = ''wrapped bad'' ', 'and keeps nothing of it')
;
-- Signing failure rolls back the grant. pgjwt.sign returns NULL rather than
-- raising when the secret is gone; the wrapper must turn that into a refusal
-- that undoes the insert, or a grant would exist that no credential names.
CREATE TEMPORARY TABLE saved_secret AS
    SELECT key, value
    FROM settings.secrets
    WHERE key = 'jwt_secret'
; DELETE FROM settings.secrets
WHERE key = 'jwt_secret'
; SELECT throws_like(' SELECT * FROM api.create_api_grant(''unsigned'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]}]'') ', '%could not be signed%', 'with no signing secret no credential is issued')
; SELECT is_empty(' SELECT id FROM data.api_grant WHERE name = ''unsigned'' ', 'and the grant that could not be signed does not exist')
; INSERT INTO settings.secrets (key, value)
SELECT key, value
FROM saved_secret
;
-- Only faculty, and only a real faculty row.
SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT throws_like(' SELECT * FROM api.create_api_grant(''by student'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]}]'') ', '%faculty%', 'a student cannot create a grant')
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT throws_like(' SELECT * FROM api.create_api_grant(''by ta'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]}]'') ', '%faculty%', 'a TA cannot create a grant')
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "1"
; SELECT throws_like(' SELECT * FROM api.create_api_grant(''by impostor'',
            ''[{"assignment_slug": "exam-1", "identity": [], "field_slugs": ["url"]}]'') ', '%current faculty%', 'a faculty claim on a non-faculty user row cannot create a grant')
;
-- ---------------------------------------------------------------
-- The pre-request hook for a grant credential (#385)
-- ---------------------------------------------------------------
-- Claims arrive as PostgREST sends them: one JSON setting. The individual
-- claim settings used above take precedence in request.jwt_claim, so they
-- are cleared first.
RESET "request.jwt.claim.role"
; RESET "request.jwt.claim.user_id"
; SELECT ok(set_config('request.jwt.claims', json_build_object('role', 'grant_consumer', 'grant_id', id, 'sub', 'grant:' || id, 'iss', 'yelukerest', 'aud', 'yelukerest-postgrest', 'exp', 4102444800)::text, false) <> '', 'present the issued credential''s claims as PostgREST would')
FROM issued
; SET "request.method" TO "GET"
; SET "request.path" TO "/rpc/granted_submissions"
; SET LOCAL role TO grant_consumer
; SELECT lives_ok('SELECT api.check_request_jwt()', 'a well-formed grant credential passes the hook on GET /rpc/granted_submissions')
; SET "request.method" TO "HEAD"
; SELECT lives_ok('SELECT api.check_request_jwt()', 'and on HEAD')
; SET "request.method" TO "POST"
; SELECT throws_like('SELECT api.check_request_jwt()', '%only read%', 'POST is refused')
; RESET "request.method"
; SELECT throws_like('SELECT api.check_request_jwt()', '%only read%', 'a request with no method is refused')
; SET "request.method" TO "GET"
; SET "request.path" TO "/api_grants"
; SELECT throws_like('SELECT api.check_request_jwt()', '%only call granted_submissions%', 'any other path is refused')
; SET "request.path" TO "/rpc/granted_submissions/"
; SELECT throws_like('SELECT api.check_request_jwt()', '%only call granted_submissions%', 'the path must match exactly')
; RESET "request.path"
; SELECT throws_like('SELECT api.check_request_jwt()', '%only call granted_submissions%', 'a request with no path is refused')
; SET "request.path" TO "/rpc/granted_submissions"
;
-- Malformed and missing claims fail closed. The grant need not exist for
-- these: the hook refuses before anything is looked up.
SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 0, "sub": "grant:0", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%grant_id%', 'grant_id 0 is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": -7, "sub": "grant:-7", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%grant_id%', 'a negative grant_id is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": "abc", "sub": "grant:abc", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%grant_id%', 'a non-numeric grant_id is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "sub": "grant:7", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%grant_id%', 'a missing grant_id is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": null, "sub": "grant:", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%grant_id%', 'a JSON-null grant_id is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 2147483648, "sub": "grant:2147483648", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%grant_id%', 'a grant_id past the int range is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 99999999999999999999, "sub": "grant:99999999999999999999", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%grant_id%', 'a huge grant_id is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 7, "sub": "grant:8", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%subject%', 'a subject naming a different grant is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 7, "sub": "user:7", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%subject%', 'a user subject on a grant credential is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 7, "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%subject%', 'a missing subject is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 7, "sub": "grant:7", "iss": "yelukerest", "aud": "yelukerest-postgrest"}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%exp%', 'a missing exp is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 7, "sub": "grant:7", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": "4102444800"}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%exp%', 'a string exp is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 7, "sub": "grant:7", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800.5}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%exp%', 'a fractional exp is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 7, "sub": "grant:7", "iss": "other", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%issuer%', 'a wrong issuer is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 7, "sub": "grant:7", "iss": "yelukerest", "exp": 4102444800}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%audience%', 'a missing audience is refused')
;
-- The audience fix applies to every role. Before it, `IF NOT (...)` let a
-- token with no aud claim at all through as SQL NULL.
SET "request.jwt.claims" TO '{"role": "student", "user_id": 1, "iss": "yelukerest", "sub": "user:1"}'
; SELECT throws_like('SELECT api.check_request_jwt()', '%audience%', 'a student token with no audience is refused too')
;
-- ---------------------------------------------------------------
-- The reader stub: credential and live grant, then refusal (#385)
-- ---------------------------------------------------------------
RESET role
; SELECT ok(set_config('request.jwt.claims', json_build_object('role', 'grant_consumer', 'grant_id', id, 'sub', 'grant:' || id, 'iss', 'yelukerest', 'aud', 'yelukerest-postgrest', 'exp', 4102444800)::text, false) <> '', 'present the issued credential''s claims again')
FROM issued
; SET LOCAL role TO grant_consumer
; SELECT is_empty(' SELECT * FROM api.granted_submissions() ', 'a live grant over an assignment with no submissions yet reads an empty set')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 424242, "sub": "grant:424242", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like(' SELECT * FROM api.granted_submissions() ', '%revoked or has expired%', 'an unknown grant is refused')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 7, "sub": "grant:8", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like(' SELECT * FROM api.granted_submissions() ', '%invalid grant credential%', 'the reader checks the subject itself, not only in the hook')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 99999999999999999999, "sub": "grant:99999999999999999999", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like(' SELECT * FROM api.granted_submissions() ', '%invalid grant credential%', 'the reader refuses a huge grant_id before casting it')
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": null, "sub": "grant:", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SELECT throws_like(' SELECT * FROM api.granted_submissions() ', '%invalid grant credential%', 'the reader refuses a JSON-null grant_id')
; SET "request.jwt.claims" TO '{"role": "student", "user_id": 1, "iss": "yelukerest", "aud": "yelukerest-postgrest", "sub": "user:1"}'
; SELECT throws_like(' SELECT * FROM api.granted_submissions() ', '%grant credential%', 'a person''s token is not a grant credential')
;
-- An expired grant, inserted directly since expiry cannot be moved through
-- the API, and the issued grant once revoked.
RESET role
; INSERT INTO data.api_grant (id, name, created_by, created_at, expires_at)
VALUES (9002, 'expired grant', 3, current_timestamp - '2 days'::interval, current_timestamp - '1 day'::interval)
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT
    ok((
        SELECT count(*) = 1
        FROM
            api.revoke_api_grant((
                SELECT id
                FROM issued
            ))
    ), 'the issued grant can be revoked')
; RESET "request.jwt.claim.role"
; RESET "request.jwt.claim.user_id"
; SET "request.jwt.claims" TO '{"role": "grant_consumer", "grant_id": 9002, "sub": "grant:9002", "iss": "yelukerest", "aud": "yelukerest-postgrest", "exp": 4102444800}'
; SET LOCAL role TO grant_consumer
; SELECT throws_like(' SELECT * FROM api.granted_submissions() ', '%revoked or has expired%', 'an expired grant is refused')
; RESET role
; SELECT ok(set_config('request.jwt.claims', json_build_object('role', 'grant_consumer', 'grant_id', id, 'sub', 'grant:' || id, 'iss', 'yelukerest', 'aud', 'yelukerest-postgrest', 'exp', 4102444800)::text, false) <> '', 'present the revoked credential''s claims')
FROM issued
; SET LOCAL role TO grant_consumer
; SELECT throws_like(' SELECT * FROM api.granted_submissions() ', '%revoked or has expired%', 'a revoked grant is refused, so revocation is live')
; RESET role
; RESET "request.jwt.claims"
;
-- ---------------------------------------------------------------
-- The reader: granted values only, paged by submission id (#386)
-- ---------------------------------------------------------------
-- A grant over three assignments: exam-1 (individual; netid, name and a
-- team_nickname that is always null there), project-update-1 (team;
-- team_nickname and a nickname that is always null there), and zz-cap (no
-- identity at all), which exists to hold enough rows to see the limit cap.
INSERT INTO data.assignment (slug, points_possible, is_draft, is_team, title, body, closed_at)
VALUES ('zz-cap', 10, false, false, 'Cap', 'b', current_timestamp + '30 days'::interval)
; INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder, is_url, is_multiline)
VALUES ('answer', 'zz-cap', 'l', 'h', 'p', false, false)
; SELECT
    ok((
        SELECT data.create_api_grant_rows('reader grant', '[{"assignment_slug": "exam-1", "identity": ["netid", "name", "team_nickname"], "field_slugs": ["url", "profound"]},
                  {"assignment_slug": "project-update-1", "identity": ["team_nickname", "nickname"], "field_slugs": ["repo-url"]},
                  {"assignment_slug": "zz-cap", "identity": [], "field_slugs": ["answer"]}]', current_timestamp + '30 days'::interval, 3) > 0
    ), 'the reader grant is created')
;
-- Four individual submissions on exam-1, with explicit ids so the paging
-- assertions below are literal. 9101 (user 1) is complete; 9102 (user 2)
-- lacks profound; 9103 (user 4) has an empty profound; 9104 (user 5) has a
-- whitespace profound, which counts as content. Written with no request
-- identity, so each field row states its origin.
INSERT INTO data.assignment_submission (id, assignment_slug, is_team, user_id, submitter_user_id)
VALUES
    (9101, 'exam-1', false, 1, 1), (9102, 'exam-1', false, 2, 2),
    (9103, 'exam-1', false, 4, 4), (9104, 'exam-1', false, 5, 5)
; INSERT INTO data.assignment_field_submission (assignment_submission_id, assignment_field_slug, assignment_slug, body, origin)
VALUES
    (9101, 'url', 'exam-1', 'https://github.com/alice/exam', 'staff'),
    (9101, 'profound', 'exam-1', 'something profound', 'staff'),
    (9102, 'url', 'exam-1', 'https://github.com/bob/exam', 'staff'),
    (9103, 'url', 'exam-1', 'https://github.com/jacob/exam', 'staff'),
    (9103, 'profound', 'exam-1', '', 'staff'),
    (9104, 'url', 'exam-1', 'https://github.com/charlotte/exam', 'staff'),
    (9104, 'profound', 'exam-1', ' ', 'staff')
;
-- 510 complete submissions on zz-cap, each from its own observer account
-- (observers get no engagement rows, so this stays cheap).
INSERT INTO data."user" (id, netid, nickname, role)
SELECT 10000 + i, 'zz' || i, 'cap-u' || i, 'observer'
FROM generate_series(1, 510) i
; INSERT INTO data.assignment_submission (id, assignment_slug, is_team, user_id, submitter_user_id)
SELECT 20000 + i, 'zz-cap', false, 10000 + i, 10000 + i
FROM generate_series(1, 510) i
; INSERT INTO data.assignment_field_submission (assignment_submission_id, assignment_field_slug, assignment_slug, body, origin)
SELECT 20000 + i, 'answer', 'zz-cap', 'answer ' || i, 'staff'
FROM generate_series(1, 510) i
; SELECT ok(set_config('request.jwt.claims', json_build_object('role', 'grant_consumer', 'grant_id', id, 'sub', 'grant:' || id, 'iss', 'yelukerest', 'aud', 'yelukerest-postgrest', 'exp', 4102444800)::text, false) <> '', 'present the reader grant''s claims')
FROM data.api_grant
WHERE name = 'reader grant'
; SET LOCAL role TO grant_consumer
;
-- Exact shape of an individual row, timestamps aside: the contracted keys,
-- the granted identity with its null team_nickname, and only the granted
-- fields.
SELECT
    "is"((
        SELECT (((r - 'created_at') - 'updated_at') #- '{fields,url,updated_at}') #- '{fields,profound,updated_at}'
        FROM api.granted_submissions('exam-1') r
        WHERE (r ->> 'submission_id')::int = 9101
    ), '{"assignment_slug": "exam-1", "submission_id": 9101, "is_team": false,
         "identity": {"netid": "abc123", "name": "Alice Miller", "team_nickname": null},
         "fields": {"url": {"body": "https://github.com/alice/exam"}, "profound": {"body": "something profound"}}}'::jsonb, 'an individual row carries the granted identity, a null team_nickname, and the granted fields only')
; SELECT set_eq(' SELECT jsonb_object_keys(r) FROM api.granted_submissions(''exam-1'') r WHERE (r ->> ''submission_id'')::int = 9101 ', ARRAY['assignment_slug', 'submission_id', 'is_team', 'created_at', 'updated_at', 'identity', 'fields'], 'a row has exactly the contracted keys')
; SELECT
    ok((
        SELECT
            (r ->> 'created_at')::timestamptz = current_timestamp
            AND (r ->> 'updated_at')::timestamptz = current_timestamp
            AND (((r -> 'fields') -> 'url') ->> 'updated_at')::timestamptz = current_timestamp
        FROM api.granted_submissions('exam-1') r
        WHERE (r ->> 'submission_id')::int = 9101
    ), 'the timestamps are the submission''s and each field row''s own')
;
-- A team row: the team, a null nickname, and not the ungranted update-url.
-- Submission 4 was edited by users 1 and 3; neither appears.
SELECT
    "is"((
        SELECT ((r - 'created_at') - 'updated_at') #- '{fields,repo-url,updated_at}'
        FROM api.granted_submissions('project-update-1') r
    ), '{"assignment_slug": "project-update-1", "submission_id": 4, "is_team": true,
         "identity": {"team_nickname": "bright-fog", "nickname": null},
         "fields": {"repo-url": {"body": "http://github.com/kljensen/fakerepo"}}}'::jsonb, 'a team row carries the team, null person keys, no editor, and the granted field only')
; SELECT
    "is"((
        SELECT r -> 'identity'
        FROM api.granted_submissions('zz-cap', NULL, 1) r
    ), '{}'::jsonb, 'an assignment granted without identity attributes yields an empty identity object')
;
-- Completeness: the submission missing a granted field and the one with an
-- empty body are absent; whitespace counts as content.
SELECT set_eq(' SELECT (r ->> ''submission_id'')::int FROM api.granted_submissions(''exam-1'') r ', ARRAY[9101, 9104], 'only submissions with every granted field non-empty are listed')
;
-- A slug the grant does not cover is an empty array, not an error.
SELECT is_empty(' SELECT * FROM api.granted_submissions(''team-selection'') ', 'an ungranted assignment reads as empty')
;
-- Ordering and paging across every granted assignment, one row at a time.
SELECT results_eq(' SELECT (r ->> ''submission_id'')::int FROM api.granted_submissions(NULL, NULL, 3) r ', ARRAY[4, 9101, 9104], 'rows come in submission id order across assignments')
; SELECT results_eq(' SELECT (r ->> ''submission_id'')::int FROM api.granted_submissions(''exam-1'', NULL, 1) r ', ARRAY[9101], 'the first page holds the lowest id')
; SELECT results_eq(' SELECT (r ->> ''submission_id'')::int FROM api.granted_submissions(''exam-1'', 9101, 1) r ', ARRAY[9104], 'p_after_id continues past the boundary')
; SELECT is_empty(' SELECT * FROM api.granted_submissions(''exam-1'', 9104, 1) ', 'and the page after the last row is empty')
;
-- Limits: refused when null or non-positive, capped at 500 otherwise.
SELECT throws_ok(' SELECT * FROM api.granted_submissions(''exam-1'', NULL, NULL) ', '22023', NULL, 'a null limit is refused')
; SELECT throws_ok(' SELECT * FROM api.granted_submissions(''exam-1'', NULL, 0) ', '22023', NULL, 'a zero limit is refused')
; SELECT throws_ok(' SELECT * FROM api.granted_submissions(''exam-1'', NULL, -1) ', '22023', NULL, 'a negative limit is refused')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.granted_submissions('zz-cap', NULL, 10000)
    ), 500, 'a limit above 500 returns 500 rows')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.granted_submissions('zz-cap', 20500, 10000)
    ), 10, 'the rows past the cap are reachable on the next page')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.granted_submissions('zz-cap')
    ), 200, 'the default limit is 200')
;
-- The listing is current state: an edit shows the new body, a filled-in
-- field brings a submission in, and a cleared field takes one out.
RESET role
; UPDATE data.assignment_field_submission
SET body = 'https://github.com/alice/exam-v2'
WHERE
    assignment_submission_id = 9101
    AND assignment_field_slug = 'url'
; INSERT INTO data.assignment_field_submission (assignment_submission_id, assignment_field_slug, assignment_slug, body, origin)
VALUES (9102, 'profound', 'exam-1', 'late but profound', 'staff')
; DELETE FROM data.assignment_field_submission
WHERE
    assignment_submission_id = 9104
    AND assignment_field_slug = 'profound'
; SET LOCAL role TO grant_consumer
; SELECT
    "is"((
        SELECT ((r -> 'fields') -> 'url') ->> 'body'
        FROM api.granted_submissions('exam-1') r
        WHERE (r ->> 'submission_id')::int = 9101
    ), 'https://github.com/alice/exam-v2', 'an edited field shows its new body')
; SELECT set_eq(' SELECT (r ->> ''submission_id'')::int FROM api.granted_submissions(''exam-1'') r ', ARRAY[9101, 9102], 'a filled-in field brings a submission in and a cleared field takes one out')
;
-- An empty page still needs a live grant: the same ungranted slug that read
-- as empty above is refused once the grant is revoked.
RESET role
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT
    ok((
        SELECT count(*) = 1
        FROM
            api.revoke_api_grant((
                SELECT id
                FROM data.api_grant
                WHERE name = 'reader grant'
            ))
    ), 'the reader grant can be revoked')
; RESET "request.jwt.claim.role"
; RESET "request.jwt.claim.user_id"
; SET LOCAL role TO grant_consumer
; SELECT throws_like(' SELECT * FROM api.granted_submissions(''team-selection'') ', '%revoked or has expired%', 'an empty page is refused once the grant is revoked')
; RESET role
; RESET "request.jwt.claims"
; SELECT *
FROM finish()
