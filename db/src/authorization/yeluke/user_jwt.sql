
-- Here, I'm setting a policy on the *view*, which
-- is different than what I normally do. The reason
-- is that I don't want TA's to be able to see 
create policy user_access_policy on api.user_jwts to api 
using (
	-- The student users can see on her or his user.
	(request.user_role() = 'student' and request.user_id() = id)
	or
	-- faculty and tas can see all users
	(request.user_role() = ANY('{faculty,ta}'::text[]) or current_user = 'authapp')
);

-- Students can read and faculty can read-write
grant select on api.user_jwts to student, ta, faculty;
