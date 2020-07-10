-- This is the only security for grade_snapshots because there
-- is no RLS and api is not the owner.
grant select, insert, update, delete on data.grade_snapshot to api;

grant select on api.grade_snapshots to student, ta;
grant select, insert, update, delete on api.grade_snapshots to faculty;
