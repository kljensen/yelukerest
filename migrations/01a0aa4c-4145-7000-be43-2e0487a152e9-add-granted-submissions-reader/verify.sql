-- Verify add-granted-submissions-reader. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema. The privilege boundary around the reader is pinned by the
-- previous migration's verify.sql; what this one adds is the reader's own
-- properties -- read-only, definer, pinned path, still owned by the narrow
-- role, and documented -- and that the stub is gone. What it returns is
-- asserted behaviourally in tests/db/yeluke-api-grants.sql.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE
            n.nspname = 'api'
            AND p.proname = 'granted_submissions'
            AND p.provolatile = 's'
            AND p.prosecdef
            AND pg_get_userbyid(p.proowner) = 'grant_reader'
            AND p.proconfig @> ARRAY['search_path=pg_catalog, data, request, pg_temp']
            AND p.prorettype = 'jsonb'::regtype
            AND p.proretset
            AND oidvectortypes(p.proargtypes) = 'text, integer, integer'
    )
;
-- The stub refused with feature_not_supported; the reader must not.
SELECT
    1 / (
        SELECT (POSITION('not yet available' IN p.prosrc) = 0)::int
        FROM
            pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE
            n.nspname = 'api'
            AND p.proname = 'granted_submissions'
    )
;
-- The paging contract is stated where a consumer reading the schema will
-- find it.
SELECT
    1 / (
        SELECT (obj_description(p.oid, 'pg_proc') LIKE '%from the start each cycle%')::int
        FROM
            pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE
            n.nspname = 'api'
            AND p.proname = 'granted_submissions'
    )
;
-- Replacing the body must not have loosened who may call it.
SELECT 1 / has_function_privilege('grant_consumer', 'api.granted_submissions(text, int, int)', 'EXECUTE')::int
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_roles r
        WHERE
            r.rolname IN ('anonymous', 'student', 'ta', 'observer', 'faculty', 'app')
            AND has_function_privilege(r.oid, 'api.granted_submissions(text, int, int)', 'EXECUTE')
    )
; SELECT 1 / (NOT has_function_privilege('public', 'api.granted_submissions(text, int, int)', 'EXECUTE'))::int
