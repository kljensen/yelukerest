-- This is the only security for quiz_grade_distributions because there
-- is no RLS and api is not the owner.
grant select on api.quiz_grade_distributions to student, ta, faculty;
