create or replace view user_jwts as
    select 
    -- Create a JWT only for faculty or for users viewing their own
    -- rows of data.
    case when
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
