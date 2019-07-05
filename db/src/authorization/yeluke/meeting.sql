
-- Let the `api` role---the view owner---query the data.
grant select, insert, update, delete on data.meeting to api;


-- There is no RLS, so the view owner can see all rows, we still need
-- to define what 
-- are the rights of our application user in regard to this api view.

-- anonymous and authenticated users can select from this view
grant select on api.meetings to student, ta, anonymous;

-- faculty have CRUD privileges
grant select, insert, update, delete on api.meetings to faculty;
