-- This is the only security for quiz_grade_stats because there
-- is no RLS and api is not the owner.
grant select on api.quiz_grade_stats to student, ta, faculty;