create or replace view assignment_fields
with (security_barrier = true) as
    select *
    from data.assignment_field AS field
    where request.user_role() = 'faculty'
    or exists (
        select 1
        from data.assignment AS assignment
        where assignment.slug = field.assignment_slug
        and assignment.is_draft = false
    );

-- it is important to set the correct owner so the RLS policy kicks in
alter view assignment_fields owner to api;
