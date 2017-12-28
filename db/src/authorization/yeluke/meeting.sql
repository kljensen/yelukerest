
-- give access to the view owner to this table
grant select, insert, update, delete on data.meeting to api;
grant usage on data.meeting_id_seq to student;


-- There is no RLS, so the view owner can see all rows, we still need
-- to define what 
-- are the rights of our application user in regard to this api view.

-- anonymous and authenticated users can select from this view
grant select on api.meetings to student, anonymous;

-- TODO: add write privileges for admin
