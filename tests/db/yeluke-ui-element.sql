
-- Plan the tests.
SELECT plan(9)
; SELECT view_owner_is('api', 'ui_elements', 'api', 'api.ui_elements view should be owned by the api role')
; SELECT table_privs_are('api', 'ui_elements', 'student', ARRAY['SELECT'], 'student should only be granted SELECT on view "api.ui_elements"')
; SELECT table_privs_are('api', 'ui_elements', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'], 'faculty should only be granted select, insert, update, delete on view "api.ui_elements"')
; SELECT table_privs_are('data', 'ui_element', 'faculty', ARRAY[]::text[], 'faculty should only be granted nothing on "data.ui_element"')
;
-- switch to a anonymous application user
SET LOCAL role TO anonymous
; SET "request.jwt.claim.role" TO anonymous
; SELECT set_eq('select key from api.ui_elements ORDER BY key', ARRAY['course-name', 'course-number', 'staff'], 'anonymous users can see all ui_elements')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SELECT set_eq('select key from api.ui_elements ORDER BY key', ARRAY['course-name', 'course-number', 'staff'], 'student users can see all ui_elements')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SELECT throws_like('INSERT INTO api.ui_elements (key, body) VALUES (''foo'', ''bar'')', '%permission denied%', 'students cannot insert into api.ui_elements')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SELECT lives_ok('INSERT INTO api.ui_elements (key, body) VALUES (''foo'', ''bar'')', 'faculty can insert into api.ui_elements')
; SELECT lives_ok('UPDATE api.ui_elements SET body = ''woot'' WHERE key = ''foo''', 'faculty can update api.ui_elements')
;
-- Finish the tests and clean up.
SELECT *
FROM finish()
