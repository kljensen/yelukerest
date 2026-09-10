-- Verify add-my-assignments-view. READ ONLY and always rolled back.
--
-- Structural: the view exists, is owned by api, keeps its security barrier,
-- exposes exactly the contracted columns in order, is commented throughout,
-- and grants SELECT to student, ta and faculty. Behaviour is asserted in
-- tests/db/yeluke-my-assignments.sql, where a failure names the case.
DO $$
DECLARE
    n int;
    cols text[];
BEGIN
    SELECT count(*) INTO n
    FROM pg_views v
    JOIN pg_class c ON c.relname = v.viewname
    JOIN pg_namespace ns ON ns.oid = c.relnamespace AND ns.nspname = v.schemaname
    WHERE v.schemaname = 'api'
      AND v.viewname = 'my_assignments'
      AND pg_get_userbyid(c.relowner) = 'api'
      AND c.reloptions @> ARRAY['security_barrier=true'];
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected api.my_assignments owned by api with a security barrier, found %', n;
    END IF;

    SELECT array_agg(a.attname::text ORDER BY a.attnum) INTO cols
    FROM pg_attribute a
    WHERE a.attrelid = 'api.my_assignments'::regclass
      AND a.attnum > 0
      AND NOT a.attisdropped;
    IF cols IS DISTINCT FROM ARRAY[
        'slug', 'title', 'is_team', 'is_draft', 'is_markdown', 'points_possible',
        'is_open', 'closed_at', 'created_at', 'updated_at', 'effective_closed_at', 'submission_window_open',
        'can_submit', 'can_submit_reason', 'extension_closed_at',
        'extension_fractional_credit', 'submissions'
    ] THEN
        RAISE EXCEPTION 'api.my_assignments columns are %', cols;
    END IF;

    SELECT count(*) INTO n
    FROM pg_attribute a
    WHERE a.attrelid = 'api.my_assignments'::regclass
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND NULLIF(btrim(col_description(a.attrelid, a.attnum)), '') IS NULL;
    IF n <> 0 OR NULLIF(btrim(obj_description('api.my_assignments'::regclass, 'pg_class')), '') IS NULL THEN
        RAISE EXCEPTION 'api.my_assignments must carry a comment on the view and on every column';
    END IF;

    SELECT count(DISTINCT grantee) INTO n
    FROM information_schema.role_table_grants
    WHERE table_schema = 'api'
      AND table_name = 'my_assignments'
      AND grantee IN ('student', 'ta', 'faculty')
      AND privilege_type = 'SELECT';
    IF n <> 3 THEN
        RAISE EXCEPTION 'student, ta and faculty should hold SELECT on api.my_assignments, found % grants', n;
    END IF;
END $$
