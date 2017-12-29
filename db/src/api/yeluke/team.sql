create or replace view teams as
    select * from data.team;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `team` table should have RLS becuase students should not
-- see each others team grades.
alter view teams owner to api;
