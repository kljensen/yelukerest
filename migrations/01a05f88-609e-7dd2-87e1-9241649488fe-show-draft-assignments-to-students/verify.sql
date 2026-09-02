-- Structural, and durable against later refactors: assert the views exist,
-- are owned by api, keep their security barrier, and still grant students
-- SELECT. Behaviour -- that a student can read a draft but cannot submit to
-- one -- is asserted in tests/db/yeluke-draft-assignment-visibility.sql, where
-- a failure names the case rather than a whole migration.
DO $$
DECLARE
    n int;
BEGIN
    SELECT count(*) INTO n
    FROM pg_views v
    JOIN pg_class c ON c.relname = v.viewname
    JOIN pg_namespace ns ON ns.oid = c.relnamespace AND ns.nspname = v.schemaname
    WHERE v.schemaname = 'api'
      AND v.viewname IN ('assignments', 'assignment_fields')
      AND pg_get_userbyid(c.relowner) = 'api'
      AND c.reloptions @> ARRAY['security_barrier=true'];
    IF n <> 2 THEN
        RAISE EXCEPTION 'expected both api views owned by api with a security barrier, found %', n;
    END IF;

    SELECT count(*) INTO n
    FROM information_schema.role_table_grants
    WHERE table_schema = 'api'
      AND table_name IN ('assignments', 'assignment_fields')
      AND grantee = 'student'
      AND privilege_type = 'SELECT';
    IF n <> 2 THEN
        RAISE EXCEPTION 'students should hold SELECT on both views, found % grants', n;
    END IF;
END $$;
