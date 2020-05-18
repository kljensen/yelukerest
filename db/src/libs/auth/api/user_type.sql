select settings.set('auth.api-schema', current_schema);
create type "user" as (id int, netid text, email text, role text);
