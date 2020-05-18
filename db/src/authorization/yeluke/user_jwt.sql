
-- Students can read and faculty can read-write
grant select on api.user_jwts to student, ta, faculty;
