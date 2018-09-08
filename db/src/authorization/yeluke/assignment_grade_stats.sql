-- This is the only security for assignment_grade_stats because there
-- is no RLS and api is not the owner.
grant select on api.assignment_grade_stats to student, ta, faculty;