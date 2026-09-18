-- Verify add-ta-quiz-import. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema. What must stay true is the boundary around the import: it
-- runs as quiz_importer and nothing else does; quiz_importer can neither log
-- in, bypass row-level security, nor act as any application role; it holds
-- exactly the table privileges the import needs on the tables this migration
-- gave it (plus, once 01a0b241 is deployed, the DELETEs its reversal needs),
-- never more than SELECT, INSERT, UPDATE and DELETE anywhere, and every one
-- of them is gated by its own policies; and faculty and TAs are exactly who
-- may call the import. What the function refuses is asserted behaviourally in
-- tests/db/yeluke-import_quiz_results.sql.
-- The owner role, provisioned outside the migration graph, NOLOGIN NOINHERIT
-- and without any cluster attribute that would let it act outside its grants.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_roles
        WHERE
            rolname = 'quiz_importer'
            AND NOT rolcanlogin
            AND NOT rolinherit
            AND NOT rolsuper
            AND NOT rolcreaterole
            AND NOT rolcreatedb
            AND NOT rolreplication
            AND NOT rolbypassrls
    )
;
-- quiz_importer is a member of nothing: in particular not api, ta or faculty.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_auth_members m
        WHERE m.member = 'quiz_importer'::regrole
    )
;
-- Who holds quiz_importer, directly or through another role: the migrator
-- and nobody else. The authenticator must not, or PostgREST could switch
-- into the role that writes grades.
WITH RECURSIVE members AS (
    SELECT m.member
    FROM pg_auth_members m
    WHERE m.roleid = 'quiz_importer'::regrole
    UNION
    SELECT m.member
    FROM
        pg_auth_members m
        JOIN members ON m.roleid = members.member
)
SELECT
    1 / (
        SELECT COALESCE(array_agg(r.rolname::text) = ARRAY['yelukerest_migrator'], false)::int
        FROM
            members
            JOIN pg_roles r ON r.oid = members.member
    )
;
-- The import: definer, owned by quiz_importer, with its search_path pinned,
-- same signature as before.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE
            n.nspname = 'api'
            AND p.proname = 'import_quiz_results'
            AND p.prosecdef
            AND pg_get_userbyid(p.proowner) = 'quiz_importer'
            AND p.proconfig @> ARRAY['search_path=pg_catalog, data, request, pg_temp']
            AND oidvectortypes(p.proargtypes) = 'jsonb, boolean, boolean, text, text'
    )
;
-- quiz_importer owns the import and, once 01a0b241 is deployed, the
-- reversal, and nothing else in any application schema. Stated as bounds
-- rather than an equality so this holds with 01a0b241 deployed or reverted;
-- that migration's verify pins the reversal itself.
SELECT
    1 / (
        SELECT
            (array_agg(p.oid::regprocedure::text) @> ARRAY['api.import_quiz_results(jsonb,boolean,boolean,text,text)']
            AND array_agg(p.oid::regprocedure::text) <@ ARRAY['api.import_quiz_results(jsonb,boolean,boolean,text,text)', 'api.revert_quiz_import(uuid,text,boolean)'])::int
        FROM pg_proc p
        WHERE p.proowner = 'quiz_importer'::regrole
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_class c
        WHERE c.relowner = 'quiz_importer'::regrole
    )
;
-- Exact execute grants, read off the ACL itself: the owner's implicit entry,
-- faculty and ta, nothing else, none grantable. Effective checks would miss
-- a grant to a role this file does not know about.
SELECT
    1 / (
        SELECT
            (array_agg(a.grantee::regrole::text || CASE
                WHEN a.is_grantable THEN ' WITH GRANT OPTION'
                ELSE ''
            END ORDER BY a.grantee::regrole::text COLLATE "C") = ARRAY['faculty', 'quiz_importer', 'ta'])::int
        FROM
            pg_proc p
            CROSS JOIN aclexplode(p.proacl) a
        WHERE
            p.oid = 'api.import_quiz_results(jsonb, boolean, boolean, text, text)'::regprocedure
            AND a.privilege_type = 'EXECUTE'
    )
; SELECT 1 / (NOT has_function_privilege('public', 'api.import_quiz_results(jsonb, boolean, boolean, text, text)', 'EXECUTE'))::int
;
-- The resolver runs only inside the definer.
SELECT 1 / has_function_privilege('quiz_importer', 'data.resolve_quiz_result_import(jsonb)', 'EXECUTE')::int
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_roles r
        WHERE
            r.rolname IN ('anonymous', 'student', 'ta', 'faculty', 'observer', 'app', 'grant_consumer', 'grant_reader', 'authapp')
            AND has_function_privilege(r.oid, 'data.resolve_quiz_result_import(jsonb)', 'EXECUTE')
    )
;
-- quiz_importer's effective schema access among the application schemas is
-- USAGE on data alone (public and request are open to every role), and
-- CREATE nowhere.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM unnest(ARRAY['api', 'auth', 'pgjwt', 'settings']) s
        WHERE has_schema_privilege('quiz_importer', s, 'USAGE')
    )
; SELECT 1 / has_schema_privilege('quiz_importer', 'data', 'USAGE')::int
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM unnest(ARRAY['api', 'auth', 'data', 'pgjwt', 'settings', 'request']) s
        WHERE has_schema_privilege('quiz_importer', s, 'CREATE')
    )
;
-- Effective table privileges on the five tables the import writes grades
-- through: the ten it needs, and beyond those at most the DELETE on quiz
-- grades and on engagements that the reversal (01a0b241) adds, so this holds
-- with that migration deployed or reverted. Effective, so PUBLIC and default
-- privileges count. Other tables are not enumerated here, since a later
-- migration may give the role more to read or write (01a0b208 adds its
-- ledger, 01a0b241 reads it and the grade events) and pins those itself;
-- what holds for every table is asserted below.
SELECT
    1 / (
        SELECT
            COALESCE(array_agg((c.oid::regclass::text || ' ') || priv) @> ARRAY['data."user" SELECT', 'data.engagement INSERT', 'data.engagement SELECT', 'data.engagement UPDATE', 'data.quiz SELECT', 'data.quiz_grade INSERT', 'data.quiz_grade SELECT', 'data.quiz_grade UPDATE', 'data.quiz_submission INSERT', 'data.quiz_submission SELECT']
            AND array_agg((c.oid::regclass::text || ' ') || priv) <@ ARRAY['data."user" SELECT', 'data.engagement DELETE', 'data.engagement INSERT', 'data.engagement SELECT', 'data.engagement UPDATE', 'data.quiz SELECT', 'data.quiz_grade DELETE', 'data.quiz_grade INSERT', 'data.quiz_grade SELECT', 'data.quiz_grade UPDATE', 'data.quiz_submission INSERT', 'data.quiz_submission SELECT'], false)::int
        FROM
            pg_class c
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN']) priv
        WHERE
            c.oid IN ('data."user"'::regclass, 'data.quiz'::regclass, 'data.quiz_submission'::regclass, 'data.quiz_grade'::regclass, 'data.engagement'::regclass)
            AND has_table_privilege('quiz_importer', c.oid, priv)
    )
;
-- On every relation in api and data: nothing in api at all, nothing on
-- anything but a plain table in data (a view would run with its owner's
-- policies, not the role's), and never a privilege that is not one of
-- SELECT, INSERT, UPDATE or DELETE.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN']) priv
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
            AND has_table_privilege('quiz_importer', c.oid, priv)
            AND (n.nspname = 'api' OR c.relkind <> 'r' OR priv NOT IN ('SELECT', 'INSERT', 'UPDATE', 'DELETE'))
    )
;
-- ...and every table privilege it does hold is on a table with row-level
-- security on, and is admitted by a quiz_importer_% policy for that command
-- and that role alone. So a grant to the role is never unconditional. The
-- one exception is SELECT on data.quiz, which has no row-level security and
-- holds nothing a faculty member or TA cannot already read.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']) priv
        WHERE
            n.nspname = 'data'
            AND c.relkind = 'r'
            AND c.oid <> 'data.quiz'::regclass
            AND has_table_privilege('quiz_importer', c.oid, priv)
            AND NOT (c.relrowsecurity
            AND EXISTS (
                SELECT 1
                FROM pg_policies p
                WHERE
                    p.schemaname = n.nspname
                    AND p.tablename = c.relname
                    AND p.cmd = priv
                    AND p.policyname LIKE 'quiz_importer_%'
                    AND p.roles = ARRAY['quiz_importer']::name[]
            ))
    )
;
-- No column privilege beyond those table privileges, and no sequence
-- privilege at all: none of the five tables has one.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_attribute a
            JOIN pg_class c ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'REFERENCES']) priv
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
            AND a.attnum > 0
            AND NOT a.attisdropped
            AND has_column_privilege('quiz_importer', c.oid, a.attnum, priv)
            AND NOT has_table_privilege('quiz_importer', c.oid, priv)
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN unnest(ARRAY['USAGE', 'SELECT', 'UPDATE']) priv
        WHERE
            n.nspname IN ('api', 'data')
            AND c.relkind = 'S'
            AND has_sequence_privilege('quiz_importer', c.oid, priv)
    )
;
-- Every table privilege the role holds on the four row-secured tables it
-- writes grades through is admitted by a policy for that role and that
-- command, and by nothing wider: nine policies, each FOR one command, each
-- TO quiz_importer alone, plus at most the quiz_grade and engagement DELETEs
-- the reversal (01a0b241) adds, and never two for one command. Policies on tables a later
-- migration added for the role are that migration's to pin.
SELECT
    1 / (
        SELECT
            COALESCE(array_agg((tablename || ' ') || cmd) @> ARRAY['engagement INSERT', 'engagement SELECT', 'engagement UPDATE', 'quiz_grade INSERT', 'quiz_grade SELECT', 'quiz_grade UPDATE', 'quiz_submission INSERT', 'quiz_submission SELECT', 'user SELECT']
            AND array_agg((tablename || ' ') || cmd) <@ ARRAY['engagement DELETE', 'engagement INSERT', 'engagement SELECT', 'engagement UPDATE', 'quiz_grade DELETE', 'quiz_grade INSERT', 'quiz_grade SELECT', 'quiz_grade UPDATE', 'quiz_submission INSERT', 'quiz_submission SELECT', 'user SELECT']
            AND count(*) = count(DISTINCT (tablename || ' ') || cmd), false)::int
        FROM pg_policies
        WHERE
            schemaname = 'data'
            AND tablename IN ('user', 'quiz_submission', 'quiz_grade', 'engagement')
            AND policyname LIKE 'quiz_importer_%'
            AND roles = ARRAY['quiz_importer']::name[]
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_policies
        WHERE
            'quiz_importer' = ANY(roles)
            AND policyname NOT LIKE 'quiz_importer_%'
    )
;
-- ...and no policy by that name is for any other role set, PUBLIC included:
-- a policy re-pointed TO PUBLIC would vanish from the two checks above.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_policies
        WHERE
            policyname LIKE 'quiz_importer_%'
            AND roles IS DISTINCT FROM ARRAY['quiz_importer']::name[]
    )
;
-- A policy TO PUBLIC on one of these tables would apply to quiz_importer as
-- well, under whatever name, and widen the backstop. Every policy on the
-- four row-secured tables is for one named role.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_policies
        WHERE
            schemaname = 'data'
            AND tablename IN ('user', 'quiz_submission', 'quiz_grade', 'engagement')
            AND (roles @> ARRAY['public']::name[] OR cardinality(roles) <> 1)
    )
;
-- The predicates themselves, whitespace-normalized from pg_policies, so a
-- deployment that widened one fails here. Every quiz_importer_% policy on
-- these four tables is in this set by the check above, so none can hide by
-- changing its roles. Under a TA claim every write is
-- confined to a quiz that is not a draft and to a student target, or once
-- 01a0b2a1 is deployed a student, TA or faculty target, never an observer;
-- a grade update or delete is faculty-only; an engagement
-- write is attendance only, absent to attended for a TA and, once 01a0b241
-- is deployed, either way for faculty, since its reversal puts attendance
-- back; faculty are otherwise unrestricted, as through the api views. Bounds
-- rather than an equality, so this holds with 01a0b241 and 01a0b2a1 each
-- deployed or reverted: the five policies neither migration touches must all
-- be present, and nothing may be present beyond them, the three INSERTs in
-- either of their two forms (student-only or staff target clause), the
-- engagement UPDATE in any of its three, and the quiz_grade and engagement
-- DELETEs. That each INSERT is present at all is the count check above; its
-- current form is 01a0b2a1's verify to pin.
SELECT
    1 / (
        SELECT
            COALESCE(array_agg((((((tablename || ' ') || cmd) || ' USING ') || COALESCE(regexp_replace(qual, E'\\s+', ' ', 'g'), '-')) || ' CHECK ') || COALESCE(regexp_replace(with_check, E'\\s+', ' ', 'g'), '-')) @> ARRAY['engagement SELECT USING (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text])) CHECK -', 'quiz_grade SELECT USING (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text])) CHECK -', 'quiz_grade UPDATE USING (request.user_role() = ''faculty''::text) CHECK (request.user_role() = ''faculty''::text)', 'quiz_submission SELECT USING (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text])) CHECK -', 'user SELECT USING (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text])) CHECK -']
            AND array_agg((((((tablename || ' ') || cmd) || ' USING ') || COALESCE(regexp_replace(qual, E'\\s+', ' ', 'g'), '-')) || ' CHECK ') || COALESCE(regexp_replace(with_check, E'\\s+', ' ', 'g'), '-')) <@ ARRAY['engagement INSERT USING - CHECK ((participation = ''attended''::data.participation_enum) AND ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = engagement.user_id) AND (u.role = ''student''::data.user_role)))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.meeting_slug = engagement.meeting_slug) AND (NOT q.is_draft)))))))', 'engagement SELECT USING (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text])) CHECK -', 'quiz_grade INSERT USING - CHECK ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = quiz_grade.user_id) AND (u.role = ''student''::data.user_role)))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.id = quiz_grade.quiz_id) AND (NOT q.is_draft))))))', 'quiz_grade SELECT USING (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text])) CHECK -', 'quiz_grade UPDATE USING (request.user_role() = ''faculty''::text) CHECK (request.user_role() = ''faculty''::text)', 'quiz_submission INSERT USING - CHECK ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = quiz_submission.user_id) AND (u.role = ''student''::data.user_role)))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.id = quiz_submission.quiz_id) AND (NOT q.is_draft))))))', 'quiz_submission SELECT USING (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text])) CHECK -', 'user SELECT USING (request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text])) CHECK -', 'engagement UPDATE USING ((request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text])) AND (participation = ''absent''::data.participation_enum)) CHECK ((participation = ''attended''::data.participation_enum) AND ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = engagement.user_id) AND (u.role = ''student''::data.user_role)))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.meeting_slug = engagement.meeting_slug) AND (NOT q.is_draft)))))))', 'engagement UPDATE USING (((request.user_role() = ''faculty''::text) AND (participation = ANY (ARRAY[''absent''::data.participation_enum, ''attended''::data.participation_enum]))) OR ((request.user_role() = ''ta''::text) AND (participation = ''absent''::data.participation_enum))) CHECK (((request.user_role() = ''faculty''::text) AND (participation = ANY (ARRAY[''absent''::data.participation_enum, ''attended''::data.participation_enum]))) OR ((request.user_role() = ''ta''::text) AND (participation = ''attended''::data.participation_enum) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = engagement.user_id) AND (u.role = ''student''::data.user_role)))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.meeting_slug = engagement.meeting_slug) AND (NOT q.is_draft))))))', 'quiz_grade DELETE USING (request.user_role() = ''faculty''::text) CHECK -', 'engagement DELETE USING ((request.user_role() = ''faculty''::text) AND (participation = ''attended''::data.participation_enum)) CHECK -', 'engagement INSERT USING - CHECK ((participation = ''attended''::data.participation_enum) AND ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = engagement.user_id) AND (u.role = ANY (ARRAY[''student''::data.user_role, ''ta''::data.user_role, ''faculty''::data.user_role]))))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.meeting_slug = engagement.meeting_slug) AND (NOT q.is_draft)))))))', 'quiz_grade INSERT USING - CHECK ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = quiz_grade.user_id) AND (u.role = ANY (ARRAY[''student''::data.user_role, ''ta''::data.user_role, ''faculty''::data.user_role]))))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.id = quiz_grade.quiz_id) AND (NOT q.is_draft))))))', 'quiz_submission INSERT USING - CHECK ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = quiz_submission.user_id) AND (u.role = ANY (ARRAY[''student''::data.user_role, ''ta''::data.user_role, ''faculty''::data.user_role]))))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.id = quiz_submission.quiz_id) AND (NOT q.is_draft))))))', 'engagement UPDATE USING (((request.user_role() = ''faculty''::text) AND (participation = ANY (ARRAY[''absent''::data.participation_enum, ''attended''::data.participation_enum]))) OR ((request.user_role() = ''ta''::text) AND (participation = ''absent''::data.participation_enum))) CHECK (((request.user_role() = ''faculty''::text) AND (participation = ANY (ARRAY[''absent''::data.participation_enum, ''attended''::data.participation_enum]))) OR ((request.user_role() = ''ta''::text) AND (participation = ''attended''::data.participation_enum) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = engagement.user_id) AND (u.role = ANY (ARRAY[''student''::data.user_role, ''ta''::data.user_role, ''faculty''::data.user_role]))))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.meeting_slug = engagement.meeting_slug) AND (NOT q.is_draft))))))'], false)::int
        FROM pg_policies
        WHERE
            schemaname = 'data'
            AND tablename IN ('user', 'quiz_submission', 'quiz_grade', 'engagement')
            AND policyname LIKE 'quiz_importer_%'
    )
;
-- Row-level security is on, and not forced, on every table the role has a
-- policy for, so the policies apply to it and the owner keeps its bypass.
SELECT
    1 / (
        SELECT (count(*) = 4)::int
        FROM pg_class c
        WHERE
            c.oid IN ('data."user"'::regclass, 'data.quiz_submission'::regclass, 'data.quiz_grade'::regclass, 'data.engagement'::regclass)
            AND c.relrowsecurity
            AND NOT c.relforcerowsecurity
    )
;
-- admin_api_version reached 11. A floor, not an equality: verification
-- re-runs against every later state of the schema, and the version only ever
-- grows. Nothing is said about schema_compatibility_version, which this
-- migration did not move and a later one may.
SELECT
    1 / (
        SELECT (admin_api_version >= 11)::int
        FROM api.platform_version
    )
