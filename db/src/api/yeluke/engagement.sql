create or replace view engagements as
    select * from data.engagement;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `engagement` table should have RLS becuase students should not
-- see each others engagement grades.
alter view engagements owner to api;
