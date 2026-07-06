-- Verify yelukerest:roles on pg

BEGIN;

\set authenticator_user `echo $DB_USER`
\set super_user `echo $SUPER_USER`

SELECT 1 / count(*) FROM pg_roles WHERE rolname = :'super_user';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = :'authenticator_user';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'anonymous';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'api';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'app';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'faculty';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'observer';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'student';
SELECT 1 / count(*) FROM pg_roles WHERE rolname = 'ta';

SELECT 1 / count(*)
FROM pg_auth_members m
JOIN pg_roles role_granted ON role_granted.oid = m.roleid
JOIN pg_roles member ON member.oid = m.member
WHERE role_granted.rolname = 'student'
AND member.rolname = :'authenticator_user';

SELECT 1 / count(*)
FROM pg_auth_members m
JOIN pg_roles role_granted ON role_granted.oid = m.roleid
JOIN pg_roles member ON member.oid = m.member
WHERE role_granted.rolname = 'faculty'
AND member.rolname = :'authenticator_user';

ROLLBACK;
