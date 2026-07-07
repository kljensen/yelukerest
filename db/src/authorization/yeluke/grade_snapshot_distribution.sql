-- This is the only security for grade_snapshot_distributions because there
-- is no RLS on this aggregate view.
grant select on api.grade_snapshot_distributions to student, ta, faculty;
