SELECT plan(7)
; SELECT view_owner_is('api', 'users', 'api', 'api.users view should be owned by the api role')
;
-- switch to a anonymous application user
SET LOCAL role TO anonymous
; SET "request.jwt.claim.role" TO anonymous
; SELECT throws_ok('select (id) from api.users', '42501', 'permission denied for view users', 'anonymous users should not be able to use the api.users view')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SELECT lives_ok('select nickname from api.users', 'faculty should be able to select from the api.users view')
; SELECT set_eq('SELECT (id) FROM api.users ORDER BY id', ARRAY[1, 2, 3, 4, 5], 'faculty should be able to select from the api.users view')
; SELECT lives_ok('UPDATE api.users SET nickname = ''rank-booger'' WHERE id=3', 'faculty should be able to update users')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT set_eq('SELECT (id) FROM api.users', ARRAY[1], 'students should only see themselves in the api.users view (1 of 2)')
; SET "request.jwt.claim.user_id" TO "2"
; SELECT set_eq('SELECT (id) FROM api.users', ARRAY[2], 'students should only see themselves in the api.users view (2 of 2)')
; SELECT *
FROM finish()
