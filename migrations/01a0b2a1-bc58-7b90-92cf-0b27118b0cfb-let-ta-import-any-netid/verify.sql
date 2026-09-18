-- Verify let-ta-import-any-netid. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema. What must stay true is that the quiz_importer write policies
-- admit a student, TA or faculty target under a TA claim and nothing else,
-- while they still confine it to a published quiz, to attendance, and to no
-- grade change; that the import is still the definer 01a0b1c5 made it, with
-- the same owner, search_path and execute grants, refusing an observer netid
-- for a TA and no longer a staff one; and that admin_api_version reached 14. What the function does and refuses
-- is asserted behaviourally in tests/db/yeluke-import_quiz_results.sql.
-- The four write policies this migration recreated, whitespace-normalized
-- from pg_policies: the draft-quiz clause, the attendance-only clause and the
-- faculty half are as before, and the target clause names exactly student,
-- ta and faculty. The grade UPDATE policy, which
-- this migration did not touch, is pinned with them: it is the record-once
-- rule at the row level and the one rule that must stay faculty-only.
SELECT
    1 / (
        SELECT COALESCE(array_agg((((((tablename || ' ') || cmd) || ' USING ') || COALESCE(regexp_replace(qual, E'\\s+', ' ', 'g'), '-')) || ' CHECK ') || COALESCE(regexp_replace(with_check, E'\\s+', ' ', 'g'), '-') ORDER BY (tablename || ' ') || cmd COLLATE "C") = ARRAY['engagement INSERT USING - CHECK ((participation = ''attended''::data.participation_enum) AND ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = engagement.user_id) AND (u.role = ANY (ARRAY[''student''::data.user_role, ''ta''::data.user_role, ''faculty''::data.user_role]))))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.meeting_slug = engagement.meeting_slug) AND (NOT q.is_draft)))))))', 'engagement UPDATE USING (((request.user_role() = ''faculty''::text) AND (participation = ANY (ARRAY[''absent''::data.participation_enum, ''attended''::data.participation_enum]))) OR ((request.user_role() = ''ta''::text) AND (participation = ''absent''::data.participation_enum))) CHECK (((request.user_role() = ''faculty''::text) AND (participation = ANY (ARRAY[''absent''::data.participation_enum, ''attended''::data.participation_enum]))) OR ((request.user_role() = ''ta''::text) AND (participation = ''attended''::data.participation_enum) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = engagement.user_id) AND (u.role = ANY (ARRAY[''student''::data.user_role, ''ta''::data.user_role, ''faculty''::data.user_role]))))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.meeting_slug = engagement.meeting_slug) AND (NOT q.is_draft))))))', 'quiz_grade INSERT USING - CHECK ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = quiz_grade.user_id) AND (u.role = ANY (ARRAY[''student''::data.user_role, ''ta''::data.user_role, ''faculty''::data.user_role]))))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.id = quiz_grade.quiz_id) AND (NOT q.is_draft))))))', 'quiz_grade UPDATE USING (request.user_role() = ''faculty''::text) CHECK (request.user_role() = ''faculty''::text)', 'quiz_submission INSERT USING - CHECK ((request.user_role() = ''faculty''::text) OR ((request.user_role() = ''ta''::text) AND (EXISTS ( SELECT 1 FROM data."user" u WHERE ((u.id = quiz_submission.user_id) AND (u.role = ANY (ARRAY[''student''::data.user_role, ''ta''::data.user_role, ''faculty''::data.user_role]))))) AND (EXISTS ( SELECT 1 FROM data.quiz q WHERE ((q.id = quiz_submission.quiz_id) AND (NOT q.is_draft))))))'], false)::int
        FROM pg_policies
        WHERE
            schemaname = 'data'
            AND tablename IN ('quiz_submission', 'quiz_grade', 'engagement')
            AND cmd IN ('INSERT', 'UPDATE')
            AND policyname LIKE 'quiz_importer_%'
            AND roles = ARRAY['quiz_importer']::name[]
    )
;
-- The import: still a definer owned by quiz_importer with its search_path
-- pinned, same signature, and its body refuses a TA target outside student,
-- ta and faculty rather than outside student alone. Read from the stored
-- body, so a later redefinition that put the old rule back fails here.
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
            AND p.prosrc LIKE '%target.role NOT IN (''student'', ''ta'', ''faculty'')%'
            AND p.prosrc LIKE '%a TA can only record grades for students, TAs and faculty, not for:%'
            AND p.prosrc NOT LIKE '%role::text <> ''student''%'
    )
;
-- ...and the other TA rules are still in the body: the reason, the draft
-- quiz read as no quiz, record-once, and the attendance bound.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_proc p
        WHERE
            p.oid = 'api.import_quiz_results(jsonb, boolean, boolean, text, text)'::regprocedure
            AND p.prosrc LIKE '%requires a non-blank p_reason from a TA%'
            AND p.prosrc LIKE '%AND (NOT caller_is_ta OR NOT quiz.is_draft)%'
            AND p.prosrc LIKE '%a TA import records grades once%'
            AND p.prosrc LIKE '%a TA request may mark attendance for at most%'
    )
;
-- Exact execute grants, unchanged by CREATE OR REPLACE: the owner's implicit
-- entry, faculty and ta, nothing else, none grantable.
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
-- admin_api_version reached 14. A floor, not an equality: verification
-- re-runs against every later state of the schema, and the version only ever
-- grows.
SELECT
    1 / (
        SELECT (admin_api_version >= 14)::int
        FROM api.platform_version
    )
