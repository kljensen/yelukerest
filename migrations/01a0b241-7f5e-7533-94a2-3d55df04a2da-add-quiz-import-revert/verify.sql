-- Verify add-quiz-import-revert. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema. What must stay true is the boundary around the reversal: it
-- is a definer owned by quiz_importer with its search_path pinned, faculty
-- alone may execute it; what quiz_importer gained for it, DELETE on quiz
-- grades and on engagements and SELECT on the ledger and the grade events,
-- is admitted only under a faculty claim; both it and the import lock rows
-- in key order; the ledger can describe a delete; and the summary shows both
-- directions. What the function does and refuses is asserted
-- behaviourally in tests/db/yeluke-revert_quiz_import.sql.
-- The reversal: definer, owned by quiz_importer, search_path pinned.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE
            n.nspname = 'api'
            AND p.proname = 'revert_quiz_import'
            AND p.prosecdef
            AND pg_get_userbyid(p.proowner) = 'quiz_importer'
            AND p.proconfig @> ARRAY['search_path=pg_catalog, data, request, pg_temp']
            AND oidvectortypes(p.proargtypes) = 'uuid, text, boolean'
    )
;
-- Exact execute grants, read off the ACL itself: the owner's implicit entry
-- and faculty, nothing else, none grantable. Not ta.
SELECT
    1 / (
        SELECT
            (array_agg(a.grantee::regrole::text || CASE
                WHEN a.is_grantable THEN ' WITH GRANT OPTION'
                ELSE ''
            END ORDER BY a.grantee::regrole::text COLLATE "C") = ARRAY['faculty', 'quiz_importer'])::int
        FROM
            pg_proc p
            CROSS JOIN aclexplode(p.proacl) a
        WHERE
            p.oid = 'api.revert_quiz_import(uuid, text, boolean)'::regprocedure
            AND a.privilege_type = 'EXECUTE'
    )
; SELECT 1 / (NOT has_function_privilege('public', 'api.revert_quiz_import(uuid, text, boolean)', 'EXECUTE'))::int
; SELECT 1 / (NOT has_function_privilege('ta', 'api.revert_quiz_import(uuid, text, boolean)', 'EXECUTE'))::int
;
-- What the owner gained: DELETE on quiz grades and engagements, SELECT on
-- the two ledger tables and the grade events. Effective, so PUBLIC and
-- default privileges count.
SELECT 1 / has_table_privilege('quiz_importer', 'data.quiz_grade', 'DELETE')::int
; SELECT 1 / has_table_privilege('quiz_importer', 'data.engagement', 'DELETE')::int
; SELECT 1 / has_table_privilege('quiz_importer', 'data.quiz_grade_import', 'SELECT')::int
; SELECT 1 / has_table_privilege('quiz_importer', 'data.quiz_grade_import_item', 'SELECT')::int
; SELECT 1 / has_table_privilege('quiz_importer', 'data.quiz_grade_event', 'SELECT')::int
;
-- ...and nothing on those three beyond SELECT: the ledger stays append-only
-- and the events untouchable, for this role as for every other.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            unnest(ARRAY['data.quiz_grade_import', 'data.quiz_grade_import_item', 'data.quiz_grade_event']) t(rel)
            CROSS JOIN unnest(ARRAY['UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN']) priv
        WHERE has_table_privilege('quiz_importer', t.rel, priv)
    )
;
-- Each of those privileges is admitted by exactly one quiz_importer policy
-- for that command, and its predicate requires a faculty claim and nothing
-- else (for an engagement, a row saying attended, the only kind an import
-- creates): which rows a reversal may delete is the function's item-driven
-- logic, not the policy's, and a TA claim is refused whatever the function
-- does. Whitespace-normalized from pg_policies.
SELECT
    1 / (
        SELECT COALESCE(array_agg((((((((tablename || ' ') || cmd) || ' ') || roles::text) || ' USING ') || COALESCE(regexp_replace(qual, E'\\s+', ' ', 'g'), '-')) || ' CHECK ') || COALESCE(regexp_replace(with_check, E'\\s+', ' ', 'g'), '-') ORDER BY (tablename || ' ') || cmd COLLATE "C") = ARRAY['engagement DELETE {quiz_importer} USING ((request.user_role() = ''faculty''::text) AND (participation = ''attended''::data.participation_enum)) CHECK -', 'quiz_grade DELETE {quiz_importer} USING (request.user_role() = ''faculty''::text) CHECK -', 'quiz_grade_event SELECT {quiz_importer} USING (request.user_role() = ''faculty''::text) CHECK -', 'quiz_grade_import SELECT {quiz_importer} USING (request.user_role() = ''faculty''::text) CHECK -', 'quiz_grade_import_item SELECT {quiz_importer} USING (request.user_role() = ''faculty''::text) CHECK -'], false)::int
        FROM pg_policies
        WHERE
            schemaname = 'data'
            AND 'quiz_importer' = ANY(roles)
            AND ((tablename IN ('quiz_grade', 'engagement')
            AND cmd = 'DELETE') OR (tablename IN ('quiz_grade_event', 'quiz_grade_import', 'quiz_grade_import_item')
            AND cmd = 'SELECT'))
    )
;
-- Row-level security is on, and not forced, on the tables those policies
-- guard.
SELECT
    1 / (
        SELECT (count(*) = 5)::int
        FROM pg_class c
        WHERE
            c.oid IN ('data.quiz_grade'::regclass, 'data.engagement'::regclass, 'data.quiz_grade_event'::regclass, 'data.quiz_grade_import'::regclass, 'data.quiz_grade_import_item'::regclass)
            AND c.relrowsecurity
            AND NOT c.relforcerowsecurity
    )
;
-- Both writers lock the rows they touch in key order: the import, redefined
-- here, and the reversal. Read from the stored bodies, so a later
-- redefinition that dropped the ORDER BY fails here.
SELECT
    1 / (
        SELECT (count(*) = 2)::int
        FROM pg_proc p
        WHERE
            p.oid IN ('api.import_quiz_results(jsonb, boolean, boolean, text, text)'::regprocedure, 'api.revert_quiz_import(uuid, text, boolean)'::regprocedure)
            AND p.prosrc ~ E'ORDER BY existing_grade\\.quiz_id, existing_grade\\.user_id\\s+FOR UPDATE OF existing_grade'
            AND p.prosrc ~ E'ORDER BY existing_engagement\\.user_id, existing_engagement\\.meeting_slug\\s+FOR UPDATE OF existing_engagement'
    )
;
-- The ledger can describe a reversal: the mutation set includes delete, the
-- after image is nullable and tied to the mutation, and the header counts
-- deleted grades and engagements.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_constraint con
        WHERE
            con.conrelid = 'data.quiz_grade_import_item'::regclass
            AND con.conname = 'quiz_grade_import_item_mutation_check'
            AND con.contype = 'c'
            AND pg_get_constraintdef(con.oid) LIKE '%''delete''%'
    )
; SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_constraint con
        WHERE
            con.conrelid = 'data.quiz_grade_import_item'::regclass
            AND con.conname = 'quiz_grade_import_item_images_match_mutation'
            AND con.contype = 'c'
    )
; SELECT
    1 / (
        SELECT (count(*) = 2)::int
        FROM pg_attribute a
        WHERE
            a.attrelid = 'data.quiz_grade_import_item'::regclass
            AND a.attname IN ('points_after', 'points_possible_after')
            AND NOT a.attnotnull
            AND NOT a.attisdropped
    )
; SELECT
    1 / (
        SELECT (count(*) = 2)::int
        FROM pg_attribute a
        WHERE
            a.attrelid = 'data.quiz_grade_import'::regclass
            AND a.attname IN ('deleted_count', 'attendance_deleted')
            AND a.attnotnull
            AND NOT a.attisdropped
    )
;
-- The summary: still owned by api, still a security barrier, still faculty
-- SELECT alone, still over both ledger tables, and carrying both directions
-- of a reversal and the delete count. A later migration may add columns; it
-- may not drop these.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE
            n.nspname = 'api'
            AND c.relname = 'quiz_grade_imports'
            AND c.relkind = 'v'
            AND pg_get_userbyid(c.relowner) = 'api'
            AND c.reloptions @> ARRAY['security_barrier=true']
    )
; SELECT 1 / has_table_privilege('faculty', 'api.quiz_grade_imports', 'SELECT')::int
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_roles r
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) priv
        WHERE
            r.rolname IN ('anonymous', 'student', 'ta', 'observer', 'app', 'grant_consumer', 'grant_reader', 'authapp', 'quiz_importer')
            AND has_table_privilege(r.oid, 'api.quiz_grade_imports', priv)
    )
; SELECT
    1 / (
        SELECT (count(DISTINCT d.refobjid) = 2)::int
        FROM
            pg_rewrite w
            JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass
            AND d.objid = w.oid
            AND d.refclassid = 'pg_class'::regclass
        WHERE
            w.ev_class = 'api.quiz_grade_imports'::regclass
            AND d.refobjid IN ('data.quiz_grade_import'::regclass, 'data.quiz_grade_import_item'::regclass)
    )
; SELECT
    1 / (
        SELECT (count(*) = 18)::int
        FROM pg_attribute a
        WHERE
            a.attrelid = 'api.quiz_grade_imports'::regclass
            AND a.attnum > 0
            AND NOT a.attisdropped
            AND a.attname IN ('id', 'label', 'actor_user_id', 'actor_role', 'reason', 'dry_run', 'created_at', 'reverts_import_id', 'reverted_by_import_id', 'inserted_count', 'updated_count', 'deleted_count', 'unchanged_count', 'submission_created_count', 'attendance_inserted', 'attendance_updated', 'attendance_deleted', 'attendance_unchanged')
    )
;
-- admin_api_version reached 13. A floor, not an equality: verification
-- re-runs against every later state of the schema, and the version only ever
-- grows.
SELECT
    1 / (
        SELECT (admin_api_version >= 13)::int
        FROM api.platform_version
    )
