create or replace view user_secrets as
    select * from data.user_secret;

-- It is important to set the correct owner so the RLS policy kicks in.
alter view user_secrets owner to api;
