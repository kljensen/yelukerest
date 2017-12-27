create or replace view meetings as
select id from data.meeting;
alter view meetings owner to api; -- it is important to set the correct owner to the RLS policy kicks in