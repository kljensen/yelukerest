create or replace view assignments as
    select assignment.*, (
        assignment.is_draft = false AND
        current_timestamp < assignment.closed_at
    ) as is_open from data.assignment;

-- it is important to set the correct owner so the RLS policy kicks in
alter view assignments owner to api;