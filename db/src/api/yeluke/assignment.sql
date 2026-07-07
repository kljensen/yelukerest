create or replace view assignments
with (security_barrier = true) as
    select assignment.*, (
        assignment.is_draft = false AND
        current_timestamp < assignment.closed_at
    ) as is_open
    from data.assignment
    where request.user_role() = 'faculty'
    or assignment.is_draft = false;

-- it is important to set the correct owner so the RLS policy kicks in
alter view assignments owner to api;
