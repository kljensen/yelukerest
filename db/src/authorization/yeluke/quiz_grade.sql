grant select, insert, update, delete on data.quiz_grade to api;

alter table data.quiz_grade enable row level security;

create policy quiz_grade_access_policy on data.quiz_grade to api 
using (
	-- The student users can see all her/his grades.
	(request.user_role() = 'student' and request.user_id() = user_id)

	or
	-- Faculty can see engagement by all users.
	(request.user_role() = 'faculty')
) WITH CHECK (
    -- Only faculty can write grades
	request.user_role() = 'faculty'
);

-- student users need to edit their answers
grant select on api.quiz_grades to student;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.quiz_grades to faculty;