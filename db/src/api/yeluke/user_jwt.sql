create or replace view user_jwts as
    select *
    from data.user;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `user` table should have RLS becuase students should not
-- see each others user grades.
alter view user_jwts owner to api;
