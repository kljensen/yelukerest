create or replace view assignments as
    select * from data.assignment;

-- it is important to set the correct owner so the RLS policy kicks in
alter view assignments owner to api;