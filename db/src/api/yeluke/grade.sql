create or replace view grades as
    select * from data.grade;

-- It is important to set the correct owner so the RLS policy kicks in.
alter view grades owner to api;
