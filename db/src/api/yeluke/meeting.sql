create or replace view meetings as
    select * from data.meeting;

-- it is important to set the correct owner so the RLS policy kicks in
alter view meetings owner to api;
