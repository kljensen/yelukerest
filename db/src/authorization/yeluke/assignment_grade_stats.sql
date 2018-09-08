-- This is the only security for assignment_grade_distributions because there
-- is no RLS and api is not the owner.
grant select on api.assignment_grade_distributions to student, ta, faculty;
