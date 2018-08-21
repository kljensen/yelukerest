-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.assignment to api;

-- No need to row level security on assignment.

-- student users can select from this view. The RLS will
-- limit them to viewing their own assignments.
grant select on api.assignments to student;
grant select on api.assignments to ta;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.assignments to faculty;
