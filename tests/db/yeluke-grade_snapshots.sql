SELECT plan(9)
; SELECT view_owner_is('api', 'grade_snapshots', 'api', 'api.grade_snapshots view should be owned by the api role')
; SELECT table_privs_are('api', 'grade_snapshots', 'student', ARRAY['SELECT'], 'student should only be granted SELECT on view "api.grade_snapshots"')
; SELECT table_privs_are('api', 'grade_snapshots', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'], 'faculty should only be granted select, insert, update, delete on view "api.grade_snapshots"')
; SELECT table_privs_are('data', 'grade_snapshot', 'faculty', ARRAY[]::text[], 'faculty should only be granted nothing on "data.grade_snapshot"')
;
-- switch to a anonymous application user
SET LOCAL role TO anonymous
; SET "request.jwt.claim.role" TO anonymous
; SELECT throws_like('select * from api.grade_snapshots', '%permission denied%', 'anonymous users should not be able to use the api.grade_snapshots view')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT set_eq('SELECT count(*) FROM api.grade_snapshots', ARRAY[1], 'students should be able to see grade snapshots')
; SELECT throws_like('UPDATE api.grade_snapshots SET slug=''foo''', '%permission denied%', 'students should NOT be able to alter a grade snapshot')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SELECT set_eq('SELECT count(*) FROM api.grade_snapshots', ARRAY[1], 'faculty should be able to see all grade snapshots')
; SELECT lives_ok('
        UPDATE api.grade_snapshots SET description=''foo'' WHERE slug = ''after-first-exam''
    ', 'faculty should be able to alter grade snapshots')
; SELECT *
FROM finish()
