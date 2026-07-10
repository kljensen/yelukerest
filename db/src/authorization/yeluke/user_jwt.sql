
-- Students can read and faculty can read-write
grant select on api.user_jwts to student, ta, faculty;
grant execute on function api.issue_user_jwt(text) to app;
