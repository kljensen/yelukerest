-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.assignment_field to api;

-- No need to row level security on assignment_field.

-- student users can select from this view. The RLS will
-- limit them to viewing their own assignment_fields.
grant select on api.assignment_fields to student;

-- faculty have CRUD privileges
grant usage on data.assignment_field_id_seq to faculty;
grant select, insert, update, delete on api.assignment_fields to faculty;
