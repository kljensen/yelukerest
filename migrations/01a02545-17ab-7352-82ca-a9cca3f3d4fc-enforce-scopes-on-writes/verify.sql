-- Verify enforce-scopes-on-writes. READ ONLY and always rolled back.

-- The hook still exists, is SECURITY DEFINER, and now mentions the scope gate.
SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'check_request_jwt'
       AND p.prosecdef
);

SELECT 1 / (
    SELECT (prosrc LIKE '%submissions:write%')::int
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'check_request_jwt'
);

-- It must still be the configured pre-request hook, or none of this runs.
SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'check_request_jwt'
       AND p.pronargs = 0
);
