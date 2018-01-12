create or replace view assignment_fields as
    select * from data.assignment_field;

-- it is important to set the correct owner so the RLS policy kicks in
alter view assignment_fields owner to api;