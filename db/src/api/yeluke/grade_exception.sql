create or replace view grade_exceptions as
    select * from data.grade_exception;

-- It is important to set the correct owner so the RLS policy kicks in.
alter view grade_exceptions owner to api;
