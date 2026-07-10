create or replace view user_jwts as
    select 
    -- Create a JWT only for faculty or for users viewing their own
    -- rows of data.
    case when
    	(
            "role" <> 'observer'::data.user_role
            AND
            (
                request.user_role() = 'faculty'
                OR
                (request.user_id() = id)
                OR
                (
                    request.user_role() = 'app'
                    AND
                    request.app_name() = 'authapp'
                )
            )
        )
    then
        auth.sign_jwt(id, "role")
    else
        null
    end as jwt,
    -- Add all other columns.
    *
    from data.user;

-- It is important to set the correct owner so the RLS policy kicks in.
-- Since we're querying the user table, the user table RLS will handle
-- row-level access. So, student are not going to be able to see other
-- students rows.
alter view user_jwts owner to api;

create or replace function issue_user_jwt(requested_netid text) returns setof user_jwts
stable
security definer
language sql
set search_path = pg_catalog, api, request, pg_temp
begin atomic
    select user_jwts.*
    from api.user_jwts
    where user_jwts.netid = requested_netid
    and request.user_role() = 'app'
    and request.app_name() = 'authapp';
end;
revoke all privileges on function issue_user_jwt(text) from public;
alter function issue_user_jwt(text) owner to api;
