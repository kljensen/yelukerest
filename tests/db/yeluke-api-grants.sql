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
; SELECT *
FROM finish()
