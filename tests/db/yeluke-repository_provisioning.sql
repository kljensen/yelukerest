-- Self-serve repositories (issue #394, roadmap 17): repository templates,
-- the GitHub identity on data."user", the template-keyed repository row,
-- the provisioning attempt and its service RPCs, and who can see and call
-- what.
--
-- Sample data this file leans on: users 1 (abc123, student, team bright-fog),
-- 2 (bde456, student, team hazy-mountain), 3 (klj39, faculty, bright-fog),
-- 4 (jlb325, ta, no team), 5 (crt43, observer); assignments exam-1
-- (individual, open), project-update-1 (team, open), team-selection
-- (individual, submissions 1-3 in field `secret`) and js-koans (draft).
--
-- The migration's backfill of pre-template repository rows is not replayed
-- here: it runs once, inside the deploy, on a column this file can no longer
-- leave NULL. What is asserted below is that every row the backfill would
-- synthesize for the sample assignments satisfies the template table's
-- constraints. The backfill itself is exercised by deploying against a
-- snapshot that holds old-style rows.
SELECT *
FROM no_plan()
;
-- ---------------------------------------------------------------------------
-- Shape and privileges
-- ---------------------------------------------------------------------------
SELECT has_table('data', 'repository_template', 'the template table exists')
; SELECT has_table('data', 'assignment_repository_provisioning', 'the attempt table exists')
; SELECT view_owner_is('api', 'repository_templates', 'api', 'the templates view is owned by api, or its policy never applies')
; SELECT view_owner_is('api', 'repository_provisionings', 'api', 'the attempts view is owned by api, or its policy never applies')
; SELECT view_owner_is('api', 'my_repositories', 'api', 'my_repositories is owned by api, or its policy never applies')
; SELECT table_privs_are('api', 'repository_templates', 'student', ARRAY['SELECT'], 'a student may only read templates')
; SELECT table_privs_are('api', 'repository_templates', 'ta', ARRAY['SELECT'], 'a ta may only read templates')
; SELECT table_privs_are('api', 'repository_templates', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'], 'faculty configure templates through the view')
; SELECT table_privs_are('api', 'repository_provisionings', 'student', ARRAY['SELECT'], 'a student may only read attempts')
; SELECT table_privs_are('api', 'repository_provisionings', 'ta', ARRAY['SELECT'], 'a ta may only read attempts')
; SELECT table_privs_are('api', 'repository_provisionings', 'faculty', ARRAY['SELECT'], 'faculty may only read attempts; the service writes them')
; SELECT table_privs_are('api', 'my_repositories', 'student', ARRAY['SELECT'], 'a student may only read my_repositories')
; SELECT table_privs_are('api', 'my_repositories', 'faculty', ARRAY['SELECT'], 'faculty may only read my_repositories')
; SELECT table_privs_are('data', 'assignment_repository_provisioning', 'faculty', ARRAY[]::text[], 'faculty hold nothing on the attempt table')
; SELECT table_privs_are('data', 'repository_template', 'faculty', ARRAY[]::text[], 'faculty hold nothing on the template table')
; SELECT function_privs_are('api', 'claim_repository_provisioning', ARRAY['text', 'integer'], 'app', ARRAY['EXECUTE'], 'the service may claim')
; SELECT function_privs_are('api', 'claim_repository_provisioning', ARRAY['text', 'integer'], 'student', ARRAY[]::text[], 'a student may not claim')
; SELECT function_privs_are('api', 'claim_repository_provisioning', ARRAY['text', 'integer'], 'faculty', ARRAY[]::text[], 'faculty may not claim')
; SELECT function_privs_are('api', 'finalize_repository_provisioning', ARRAY['integer', 'bigint'], 'student', ARRAY[]::text[], 'a student may not finalize')
; SELECT function_privs_are('api', 'set_user_github_identity', ARRAY['integer', 'bigint', 'text', 'boolean'], 'faculty', ARRAY[]::text[], 'faculty may not set a GitHub identity directly')
; SELECT function_privs_are('api', 'import_github_logins', ARRAY['text', 'text'], 'faculty', ARRAY['EXECUTE'], 'faculty may run the login import')
; SELECT function_privs_are('api', 'import_github_logins', ARRAY['text', 'text'], 'app', ARRAY[]::text[], 'the service may not run the login import')
; SELECT function_privs_are('api', 'import_github_logins', ARRAY['text', 'text'], 'student', ARRAY[]::text[], 'a student may not run the login import')
; SELECT hasnt_column('data', 'assignment', 'repository_template_provider', 'the template no longer lives on the assignment')
; SELECT hasnt_column('data', 'assignment', 'repository_url_field_slug', 'nor does a designated URL field')
; SELECT hasnt_column('api', 'my_assignments', 'repository_template_full_name', 'my_assignments carries no template columns')
; SELECT col_is_null('data', 'assignment_repository', 'assignment_slug', 'a repository need not name an assignment')
; SELECT col_not_null('data', 'assignment_repository', 'template_slug', 'but it always names its template')
;
-- ---------------------------------------------------------------------------
-- Templates: shape, and what the backfill would produce
-- ---------------------------------------------------------------------------
SELECT lives_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label, description, assignment_slug)
        VALUES (''exam-1-starter'', ''yale-mgt-656/exam-1-starter'', ''Exam 1 starter'', ''Start here for the first exam'', ''exam-1'')
    ', 'an individual template can serve an individual assignment')
; SELECT lives_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label, is_team, assignment_slug)
        VALUES (''project-starter'', ''yale-mgt-656/project-starter'', ''Project starter'', true, ''project-update-1'')
    ', 'a team template can serve a team assignment')
; SELECT lives_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label)
        VALUES (''go-starter'', ''yale-mgt-656/go-starter'', ''Go programming starter'')
    ', 'a template need not serve any assignment')
; SELECT lives_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label, is_active)
        VALUES (''retired-starter'', ''yale-mgt-656/retired'', ''Retired'', false)
    ', 'a template can be inactive')
; SELECT lives_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label, assignment_slug)
        VALUES (''draft-starter'', ''yale-mgt-656/koans'', ''Koans'', ''js-koans'')
    ', 'a template can serve a draft assignment')
; SELECT throws_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label, is_team, assignment_slug)
        VALUES (''wrong-kind'', ''yale-mgt-656/x'', ''x'', true, ''exam-1'')
    ', '23503', NULL, 'a team template cannot serve an individual assignment')
; SELECT throws_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label)
        VALUES (''Bad Slug'', ''yale-mgt-656/x'', ''x'')
    ', '23514', NULL, 'the slug is slug-shaped')
; SELECT throws_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label)
        VALUES (''bad-template'', ''not a repo'', ''x'')
    ', '23514', NULL, 'the template must be owner/repo')
; SELECT throws_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label)
        VALUES (''bad-label'', ''yale-mgt-656/x'', '''')
    ', '23514', NULL, 'a label cannot be empty')
;
-- What the deploy's backfill synthesizes for a pre-template row -- slug =
-- the assignment slug, 'unknown/' || slug, label = the title -- has to pass
-- the same constraints for every sample assignment, or a real deploy over
-- old rows would fail.
SELECT lives_ok('
        INSERT INTO data.repository_template (slug, template_full_name, label, is_team, assignment_slug)
        SELECT a.slug, ''unknown/'' || a.slug, coalesce(nullif(a.title, ''''), a.slug), a.is_team, a.slug
        FROM data.assignment a
    ', 'the backfill''s synthesized template is admitted for every sample assignment')
; DELETE FROM data.repository_template
WHERE template_full_name LIKE 'unknown/%'
;
-- Faculty configure through the view; students read the active ones and
-- cannot write.
SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SET "request.jwt.claim.app_name" TO ''
; SELECT lives_ok('
        INSERT INTO api.repository_templates (slug, template_full_name, label)
        VALUES (''faculty-made'', ''yale-mgt-656/faculty-made'', ''Made by faculty'')
    ', 'faculty can create a template through api.repository_templates')
; SELECT lives_ok('UPDATE api.repository_templates SET description = ''one line'' WHERE slug = ''faculty-made''', 'and update one')
; SELECT lives_ok('DELETE FROM api.repository_templates WHERE slug = ''faculty-made''', 'and delete one')
; SELECT set_eq('SELECT slug FROM api.repository_templates', ARRAY['exam-1-starter', 'project-starter', 'go-starter', 'retired-starter', 'draft-starter'], 'faculty see every template, active or not')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT set_eq('SELECT slug FROM api.repository_templates', ARRAY['exam-1-starter', 'project-starter', 'go-starter', 'draft-starter'], 'a student sees the active templates')
; SELECT throws_ok('
        INSERT INTO api.repository_templates (slug, template_full_name, label)
        VALUES (''evil'', ''evil/template'', ''x'')
    ', '42501', NULL, 'a student cannot create a template')
; SELECT throws_ok('UPDATE api.repository_templates SET template_full_name = ''evil/template'' WHERE slug = ''exam-1-starter''', '42501', NULL, 'a student cannot change a template')
; RESET role
;
-- ---------------------------------------------------------------------------
-- GitHub identity: shape and uniqueness
-- ---------------------------------------------------------------------------
SELECT lives_ok('UPDATE data."user" SET github_user_id = 1001, github_login = ''alice-m'' WHERE id = 1', 'a user can hold a GitHub account id and login')
; SELECT throws_ok('UPDATE data."user" SET github_user_id = 1001 WHERE id = 2', '23505', NULL, 'one GitHub account belongs to one user')
; SELECT throws_ok('UPDATE data."user" SET github_user_id = 0 WHERE id = 2', '23514', NULL, 'the account id must be positive')
; SELECT throws_ok('UPDATE data."user" SET github_login = ''-alice'' WHERE id = 2', '23514', NULL, 'a login cannot start with a hyphen')
; SELECT throws_ok('UPDATE data."user" SET github_login = ''al--ice'' WHERE id = 2', '23514', NULL, 'a login cannot double a hyphen')
; SELECT throws_ok('UPDATE data."user" SET github_login = repeat(''a'', 40) WHERE id = 2', '23514', NULL, 'a login is at most 39 characters')
; SELECT lives_ok('UPDATE data."user" SET github_login = ''bob'' WHERE id = 5', 'a plain login is accepted')
; SELECT throws_ok('UPDATE data."user" SET github_login = ''BOB'' WHERE id = 2', '23505', NULL, 'one login belongs to one user, whatever its case')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT results_eq('SELECT github_user_id, github_login, github_verified_at FROM api.users', ' VALUES (1001::bigint, ''alice-m''::text, NULL::timestamptz) ', 'a student sees their own GitHub identity and nobody else''s')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT throws_ok('UPDATE api.users SET github_verified_at = current_timestamp WHERE id = 1', '42501', NULL, 'faculty cannot forge a verification through api.users')
; SELECT throws_ok('UPDATE api.users SET github_login = ''someone'' WHERE id = 1', '42501', NULL, 'faculty cannot write a login through api.users')
; SELECT lives_ok('UPDATE api.users SET known_as = ''Al'' WHERE id = 1', 'faculty still update the columns they always could')
; RESET role
;
-- ---------------------------------------------------------------------------
-- The service RPCs refuse everyone but authapp
-- ---------------------------------------------------------------------------
SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1-starter'', 1)', '42501', NULL, 'a student holds no EXECUTE on claim')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(1, ''failed'')', '42501', NULL, 'a student holds no EXECUTE on record')
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(1)', '42501', NULL, 'a student holds no EXECUTE on finalize')
; SELECT throws_ok('SELECT * FROM api.touch_repository_provisioning_readiness(1, true)', '42501', NULL, 'a student holds no EXECUTE on touch')
; SELECT throws_ok('SELECT * FROM api.set_user_github_identity(1, 1, ''x'', true)', '42501', NULL, 'a student holds no EXECUTE on set_user_github_identity')
; SELECT throws_ok('SELECT api.import_github_logins(''team-selection'', ''secret'')', '42501', NULL, 'a student holds no EXECUTE on import_github_logins')
; RESET role
;
-- The function's own check, beneath the grant: a student claim carried by a
-- role that can execute, and the other service, are refused by name.
SELECT throws_like('SELECT * FROM api.claim_repository_provisioning(''exam-1-starter'', 1)', '%insufficient_privilege%', 'claim refuses a student claim inside the function')
; SET "request.jwt.claim.role" TO app
; SET "request.jwt.claim.user_id" TO ''
; SET "request.jwt.claim.app_name" TO mcpapp
; SELECT throws_like('SELECT * FROM api.set_user_github_identity(1, 1001, ''alice-m'', true)', '%insufficient_privilege%', 'mcpapp is not authapp')
; SELECT throws_like('SELECT api.import_github_logins(''team-selection'', ''secret'')', '%insufficient_privilege%', 'the login import is faculty-only, not for the service')
;
-- A service claim with no app_name at all is refused, not waved through: the
-- guard has to fail closed on a NULL claim.
SET "request.jwt.claim.app_name" TO ''
; SELECT throws_like('SELECT * FROM api.claim_repository_provisioning(''exam-1-starter'', 1)', '%insufficient_privilege%', 'claim refuses role app without an app_name')
; SELECT throws_like('SELECT * FROM api.record_repository_provisioning(1, ''failed'', NULL, NULL, ''x'')', '%insufficient_privilege%', 'record refuses role app without an app_name')
; SELECT throws_like('SELECT * FROM api.finalize_repository_provisioning(1)', '%insufficient_privilege%', 'finalize refuses role app without an app_name')
; SELECT throws_like('SELECT * FROM api.touch_repository_provisioning_readiness(1, true)', '%insufficient_privilege%', 'touch refuses role app without an app_name')
; SELECT throws_like('SELECT * FROM api.set_user_github_identity(1, 1001, ''alice-m'', true)', '%insufficient_privilege%', 'set_user_github_identity refuses role app without an app_name')
;
-- ---------------------------------------------------------------------------
-- Claim, as authapp
-- ---------------------------------------------------------------------------
SET "request.jwt.claim.app_name" TO authapp
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''no-such-template'', 1)', 'P0001', 'template_not_found', 'an unknown template cannot be claimed')
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''retired-starter'', 1)', 'P0001', 'template_inactive', 'nor an inactive one')
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1-starter'', 4)', 'P0001', 'not_a_student', 'a ta cannot claim a repository')
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1-starter'', 3)', 'P0001', 'not_a_student', 'nor can faculty')
; UPDATE data."user"
SET team_nickname = NULL
WHERE id = 2
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''project-starter'', 2)', 'P0001', 'no_team', 'a team template needs the student on a team')
; UPDATE data."user"
SET team_nickname = 'hazy-mountain'
WHERE id = 2
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1-starter'', 2)', 'P0001', 'needs_github_link', 'an individual template needs the student''s GitHub login')
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''draft-starter'', 1)', 'P0001', 'assignment_closed', 'a template serving a draft assignment is closed')
;
-- Closed for the owner through the template's assignment, unless an
-- extension reopens it.
INSERT INTO data.assignment (slug, points_possible, is_draft, is_team, title, body, closed_at)
VALUES ('zz-closed', 10, false, false, 'Closed', 'b', current_timestamp - '1 day'::interval)
; INSERT INTO data.repository_template (slug, template_full_name, label, assignment_slug)
VALUES ('closed-starter', 'yale-mgt-656/closed-template', 'Closed starter', 'zz-closed')
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''closed-starter'', 1)', 'P0001', 'assignment_closed', 'a template serving a closed assignment cannot be claimed')
; INSERT INTO data.assignment_grade_exception (assignment_slug, user_id, closed_at, fractional_credit)
VALUES ('zz-closed', 1, current_timestamp + '7 days'::interval, 1)
; SELECT
    "is"((
        SELECT stage
        FROM api.claim_repository_provisioning('closed-starter', 1)
    ), 'claimed', 'an extension reopens the assignment for its holder')
; UPDATE data."user"
SET github_login = 'bob-f'
WHERE id = 2
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''closed-starter'', 2)', 'P0001', 'assignment_closed', 'and for nobody else')
; UPDATE data."user"
SET github_login = NULL
WHERE id = 2
;
-- A fresh claim.
SELECT results_eq('
        SELECT template_slug, is_team, user_id, team_nickname, initiated_by_user_id,
               provider, template_full_name, destination_name, provider_repo_id, stage,
               error_code, existing_repository_id
        FROM api.claim_repository_provisioning(''exam-1-starter'', 1)
    ', ' VALUES (''exam-1-starter''::text, false, 1, NULL::text, 1, ''github''::text, ''yale-mgt-656/exam-1-starter''::text,
                 ''exam-1-starter-alice-m''::text, NULL::bigint, ''claimed''::text, NULL::text, NULL::int) ', 'a fresh claim creates an attempt named after the template and the login')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.assignment_repository_provisioning
        WHERE
            template_slug = 'exam-1-starter'
            AND user_id = 1
    ), 1, 'one attempt row was written')
; SELECT
    "is"((
        SELECT count(DISTINCT id)::int
        FROM
            (
                (
                    SELECT id
                    FROM api.claim_repository_provisioning('exam-1-starter', 1)
                    UNION ALL
                    SELECT id
                    FROM api.claim_repository_provisioning('exam-1-starter', 1)
                )
                UNION ALL
                SELECT id
                FROM data.assignment_repository_provisioning
                WHERE
                    template_slug = 'exam-1-starter'
                    AND user_id = 1
            ) ids
    ), 1, 'claiming again resumes the same attempt')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.assignment_repository_provisioning
    ), 2, 'no second attempt was created')
; SELECT results_eq('
        SELECT template_slug, destination_name, stage
        FROM api.claim_repository_provisioning(''go-starter'', 1)
    ', ' VALUES (''go-starter''::text, ''go-starter-alice-m''::text, ''claimed''::text) ', 'a template serving no assignment is always open')
;
-- ---------------------------------------------------------------------------
-- Record: the transitions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION zapadka_test.attempt(p_slug text, p_user int) RETURNS int LANGUAGE sql STABLE AS $$
    SELECT id FROM data.assignment_repository_provisioning WHERE template_slug = p_slug AND user_id = p_user
$$
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''granted'')', 'P0001', 'invalid_stage_transition', 'claimed cannot jump to granted')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''finalized'')', 'P0001', 'invalid_stage_transition', 'finalized is reached through finalize, not record')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''generated'')', '22023', NULL, 'generated needs the forge id and name')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''bogus'')', 'P0001', 'invalid_stage_transition', 'an unknown stage is refused')
; SELECT results_eq('
        SELECT stage, provider_repo_id, provider_full_name
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''generated'', 500001, ''yale-mgt-656/exam-1-starter-alice-m'')
    ', ' VALUES (''generated''::text, 500001::bigint, ''yale-mgt-656/exam-1-starter-alice-m''::text) ', 'claimed becomes generated with the repository the forge returned')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''claimed'')', 'P0001', 'invalid_stage_transition', 'generated cannot go back to claimed')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''generated'', 500009, ''yale-mgt-656/exam-1-starter-alice-m'')', 'P0001', 'invalid_stage_transition', 'a repeated generated naming a different repository is refused')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''granted'', 500001, ''yale-mgt-656/exam-1-starter-alice-m'')', '22023', NULL, 'a repository is recorded on generated only')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''failed'')', '22023', NULL, 'a failure needs an error code')
; SELECT results_eq('
        SELECT stage, error_code, provider_repo_id
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''failed'', NULL, NULL, ''github_timeout'')
    ', ' VALUES (''failed''::text, ''github_timeout''::text, 500001::bigint) ', 'any unfinalized stage can fail, with a code, keeping what the forge said')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''failed'', NULL, NULL, ''GitHub said: 502 Bad Gateway'')', '23514', NULL, 'an error code is a stable token, never a raw forge message')
; SELECT results_eq('
        SELECT stage, error_code
        FROM api.claim_repository_provisioning(''exam-1-starter'', 1)
    ', ' VALUES (''claimed''::text, NULL::text) ', 'claiming a failed attempt resets it to claimed')
; SELECT results_eq('
        SELECT stage
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''generated'', 500001, ''yale-mgt-656/exam-1-starter-alice-m'')
    ', ' VALUES (''generated''::text) ', 'the reset attempt moves forward again')
; SELECT results_eq('
        SELECT stage
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''generated'', 500001, ''yale-mgt-656/exam-1-starter-alice-m'')
    ', ' VALUES (''generated''::text) ', 'recording the same stage again is a harmless repeat')
; SELECT results_eq('
        SELECT stage
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''granted'')
    ', ' VALUES (''granted''::text) ', 'generated becomes granted')
;
-- ---------------------------------------------------------------------------
-- Readiness
-- ---------------------------------------------------------------------------
SELECT throws_ok('SELECT * FROM api.touch_repository_provisioning_readiness(zapadka_test.attempt(''closed-starter'', 1), true)', 'P0001', 'invalid_stage_transition', 'a claimed attempt has no repository to check')
; SELECT results_eq('
        SELECT last_checked_at IS NOT NULL, ready_at
        FROM api.touch_repository_provisioning_readiness(zapadka_test.attempt(''exam-1-starter'', 1), false)
    ', ' VALUES (true, NULL::timestamptz) ', 'a check that found nothing ready records the check only')
; SELECT
    ok((
        SELECT ready_at IS NOT NULL
        FROM api.touch_repository_provisioning_readiness(zapadka_test.attempt('exam-1-starter', 1), true)
    ), 'a ready check sets ready_at')
; SELECT
    "is"((
        SELECT count(DISTINCT ready_at)::int
        FROM
            (
                SELECT ready_at
                FROM api.touch_repository_provisioning_readiness(zapadka_test.attempt('exam-1-starter', 1), true)
                UNION ALL
                SELECT ready_at
                FROM data.assignment_repository_provisioning
                WHERE id = zapadka_test.attempt('exam-1-starter', 1)
            ) t
    ), 1, 'ready_at is set once and never moved')
;
-- ---------------------------------------------------------------------------
-- Finalize: the repository row, and nothing else
-- ---------------------------------------------------------------------------
SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), 9999)', 'P0001', 'github_identity_mismatch', 'the account the repository was granted to must be the one the student linked')
; SELECT is_empty('SELECT 1 FROM data.assignment_repository WHERE template_slug = ''exam-1-starter''', 'a refused finalize wrote no repository')
; SELECT results_eq('
        SELECT template_slug, assignment_slug, is_team, user_id, provider, provider_repo_id, provider_full_name, provider_user_id
        FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), 1001)
    ', ' VALUES (''exam-1-starter''::text, ''exam-1''::text, false, 1, ''github''::text, 500001::bigint, ''yale-mgt-656/exam-1-starter-alice-m''::text, 1001::bigint) ', 'finalize records the repository for the owner and template, with the assignment the template serves')
; SELECT is_empty('SELECT 1 FROM data.assignment_submission WHERE assignment_slug = ''exam-1''', 'finalize wrote no submission')
; SELECT is_empty('SELECT 1 FROM data.assignment_field_submission WHERE assignment_slug = ''exam-1''', 'and no field submission')
; SELECT
    "is"((
        SELECT stage
        FROM data.assignment_repository_provisioning
        WHERE id = zapadka_test.attempt('exam-1-starter', 1)
    ), 'finalized', 'the attempt is finalized')
; SELECT results_eq('
        SELECT provider_repo_id
        FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), 1001)
    ', ' VALUES (500001::bigint) ', 'finalizing again returns the repository and changes nothing')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.assignment_repository
    ), 1, 'a repeated finalize adds no row')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 1), ''failed'', NULL, NULL, ''late'')', 'P0001', 'already_finalized', 'a finalized attempt is immutable')
; SELECT results_eq('
        SELECT id = zapadka_test.attempt(''exam-1-starter'', 1) AS same_attempt, stage, provider_repo_id, existing_repository_id IS NOT NULL AS has_repository
        FROM api.claim_repository_provisioning(''exam-1-starter'', 1)
    ', ' VALUES (true, ''finalized''::text, 500001::bigint, true) ', 'claiming after finalize returns the finalized row with the repository')
;
-- A template serving no assignment finalizes into a row with no assignment.
SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''go-starter'', 1), ''generated'', 500003, ''yale-mgt-656/go-starter-alice-m'')', 'the go attempt is generated')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''go-starter'', 1), ''granted'')', 'and granted')
; SELECT results_eq('
        SELECT template_slug, assignment_slug, user_id
        FROM api.finalize_repository_provisioning(zapadka_test.attempt(''go-starter'', 1))
    ', ' VALUES (''go-starter''::text, NULL::text, 1) ', 'a repository from a template with no assignment names no assignment')
;
-- A repository the old course tooling recorded, with no attempt at all: it
-- answers the claim before the login or the deadline is looked at.
INSERT INTO data.assignment_repository (template_slug, assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
VALUES ('closed-starter', 'zz-closed', false, 2, 500004, 'yale-mgt-656/zz-closed-bob')
; SELECT results_eq('
        SELECT id, stage, provider_full_name, destination_name, existing_repository_id IS NOT NULL
        FROM api.claim_repository_provisioning(''closed-starter'', 2)
    ', ' VALUES (NULL::int, ''finalized''::text, ''yale-mgt-656/zz-closed-bob''::text, ''zz-closed-bob''::text, true) ', 'an existing repository answers a claim without an attempt, even for a student with no login on a closed assignment')
;
-- A team attempt.
SELECT results_eq('
        SELECT is_team, team_nickname, initiated_by_user_id, destination_name
        FROM api.claim_repository_provisioning(''project-starter'', 1)
    ', ' VALUES (true, ''bright-fog''::text, 1, ''project-starter-bright-fog''::text) ', 'a team claim names the team')
; CREATE OR REPLACE FUNCTION zapadka_test.team_attempt(p_slug text, p_team text) RETURNS int LANGUAGE sql STABLE AS $$
    SELECT id FROM data.assignment_repository_provisioning WHERE template_slug = p_slug AND team_nickname = p_team
$$
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.team_attempt(''project-starter'', ''bright-fog''))', 'P0001', 'invalid_stage_transition', 'only a granted attempt can be finalized')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.team_attempt(''project-starter'', ''bright-fog''), ''generated'', 500002, ''yale-mgt-656/project-starter-bright-fog'')', 'the team attempt is generated')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.team_attempt(''project-starter'', ''bright-fog''), ''granted'')', 'and granted')
; SELECT results_eq('
        SELECT team_nickname, assignment_slug, provider_repo_id
        FROM api.finalize_repository_provisioning(zapadka_test.team_attempt(''project-starter'', ''bright-fog''))
    ', ' VALUES (''bright-fog''::text, ''project-update-1''::text, 500002::bigint) ', 'a team attempt finalizes into a team repository')
; SELECT
    "is"((
        SELECT body
        FROM data.assignment_field_submission
        WHERE
            assignment_submission_id = 4
            AND assignment_field_slug = 'repo-url'
    ), 'http://github.com/kljensen/fakerepo', 'the team''s existing submission is untouched')
;
-- A different repository already recorded for the owner, and the same forge
-- repository already recorded for another owner.
SELECT lives_ok('SELECT * FROM api.set_user_github_identity(2, 1002, ''bob-f'', false)', 'user 2 links an account')
; SELECT lives_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1-starter'', 2)', 'user 2 claims exam-1-starter')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 2), ''generated'', 600001, ''yale-mgt-656/exam-1-starter-bob'')', 'generated')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 2), ''granted'')', 'granted')
; INSERT INTO data.assignment_repository (template_slug, assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
VALUES ('exam-1-starter', 'exam-1', false, 2, 600002, 'yale-mgt-656/exam-1-bob-by-hand')
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1-starter'', 2))', 'P0001', 'repository_conflict', 'a different repository already on record for the owner is a conflict')
; SELECT lives_ok('SELECT * FROM api.claim_repository_provisioning(''go-starter'', 2)', 'user 2 claims go-starter')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''go-starter'', 2), ''generated'', 500001, ''yale-mgt-656/exam-1-starter-alice-m'')', 'the forge answers with a repository somebody else already holds')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''go-starter'', 2), ''granted'')', 'granted')
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.attempt(''go-starter'', 2))', 'P0001', 'repository_conflict', 'a forge repository recorded for another owner is a conflict')
;
-- ---------------------------------------------------------------------------
-- my_repositories
-- ---------------------------------------------------------------------------
-- On the board: user 1's exam-1-starter and go-starter repositories,
-- bright-fog's project-starter repository, user 2's closed-starter and
-- by-hand exam-1-starter rows.
SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT results_eq('
        SELECT template_slug, label, assignment_slug, template_full_name, is_team, repo_url
        FROM api.my_repositories ORDER BY template_slug
    ', ' VALUES
        (''exam-1-starter''::text, ''Exam 1 starter''::text, ''exam-1''::text, ''yale-mgt-656/exam-1-starter''::text, false, ''https://github.com/yale-mgt-656/exam-1-starter-alice-m''::text),
        (''go-starter'', ''Go programming starter'', NULL, ''yale-mgt-656/go-starter'', false, ''https://github.com/yale-mgt-656/go-starter-alice-m''),
        (''project-starter'', ''Project starter'', ''project-update-1'', ''yale-mgt-656/project-starter'', true, ''https://github.com/yale-mgt-656/project-starter-bright-fog'')
    ', 'a student sees their own and their team''s repositories with the template''s label and assignment and the browser URL')
; SET "request.jwt.claim.user_id" TO "2"
; SELECT set_eq('SELECT template_slug FROM api.my_repositories', ARRAY['closed-starter', 'exam-1-starter'], 'the other student sees only their own')
; RESET role
;
-- Deactivating a template hides it from the page but not from the students
-- whose repositories came from it.
UPDATE data.repository_template
SET is_active = false
WHERE slug = 'exam-1-starter'
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT
    "is"((
        SELECT label
        FROM api.my_repositories
        WHERE template_slug = 'exam-1-starter'
    ), 'Exam 1 starter', 'a repository from a deactivated template keeps its label on my_repositories')
; SELECT
    ok((
        SELECT count(*) = 1
        FROM api.repository_templates
        WHERE slug = 'exam-1-starter'
    ), 'and its owner still reads the template')
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT is_empty('SELECT slug FROM api.repository_templates WHERE slug IN (''exam-1-starter'', ''retired-starter'')', 'a ta with no repository from it does not read a deactivated template')
; RESET role
; SET "request.jwt.claim.role" TO app
; SET "request.jwt.claim.user_id" TO ''
; SET "request.jwt.claim.app_name" TO authapp
; UPDATE data.repository_template
SET is_active = true
WHERE slug = 'exam-1-starter'
;
-- ---------------------------------------------------------------------------
-- The GitHub identity, as authapp
-- ---------------------------------------------------------------------------
SELECT results_eq('
        SELECT github_user_id, github_login, github_verified_at IS NOT NULL
        FROM api.set_user_github_identity(4, 1004, ''jacob-b'', true)
    ', ' VALUES (1004::bigint, ''jacob-b''::text, true) ', 'a verified link sets the identity and verified_at')
; SELECT throws_ok('SELECT * FROM api.set_user_github_identity(5, 1004, ''jacob-b'', true)', 'P0001', 'github_identity_taken', 'an account held by another user is refused')
; SELECT throws_ok('SELECT * FROM api.set_user_github_identity(4, 1004, ''Bob-F'', true)', 'P0001', 'github_identity_taken', 'a login another user holds is refused, whatever its case, and not as a bare unique violation')
; SELECT throws_ok('SELECT * FROM api.set_user_github_identity(2, 1098, ''bob-g'', false)', 'P0001', 'github_identity_locked', 'a repository the old tooling recorded locks the account too')
; SELECT throws_ok('SELECT * FROM api.set_user_github_identity(1, 1099, ''alice-new'', false)', 'P0001', 'github_identity_locked', 'a user with a provisioned repository cannot switch accounts')
; SELECT results_eq('
        SELECT github_user_id, github_login, github_verified_at
        FROM api.set_user_github_identity(1, 1001, ''alice-renamed'', false)
    ', ' VALUES (1001::bigint, ''alice-renamed''::text, NULL::timestamptz) ', 'the same account under a new login is a rename, not a switch')
; SELECT
    ok((
        SELECT github_verified_at IS NOT NULL
        FROM api.set_user_github_identity(4, 1004, 'jacob-b', false)
    ), 'an unverified call for the same account never downgrades a verified row')
; SELECT results_eq('
        SELECT github_user_id, github_verified_at
        FROM api.set_user_github_identity(4, 1005, ''jacob-b'', false)
    ', ' VALUES (1005::bigint, NULL::timestamptz) ', 'an unverified call naming another account, for a user with nothing provisioned, switches and clears verified_at')
;
-- ---------------------------------------------------------------------------
-- The faculty bootstrap import
-- ---------------------------------------------------------------------------
-- team-selection's `secret` field holds one value per student in the sample
-- data; users 1 and 2 already have logins, so only user 3 is a candidate.
SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SET "request.jwt.claim.app_name" TO ''
; UPDATE data.assignment_field_submission
SET body = 'not a login!'
WHERE
    assignment_submission_id = 3
    AND assignment_field_slug = 'secret'
; SELECT "is"(api.import_github_logins('team-selection', 'secret'), 0, 'a body that is not a login is skipped, not imported')
; UPDATE data.assignment_field_submission
SET body = 'BOB-F'
WHERE
    assignment_submission_id = 3
    AND assignment_field_slug = 'secret'
; SELECT "is"(api.import_github_logins('team-selection', 'secret'), 0, 'a login another user holds is skipped, whatever its case')
; SELECT
    "is"((
        SELECT github_login
        FROM data."user"
        WHERE id = 3
    ), NULL, 'and the user is left without a login')
; UPDATE data.assignment_field_submission
SET body = '  kljensen '
WHERE
    assignment_submission_id = 3
    AND assignment_field_slug = 'secret'
; SELECT "is"(api.import_github_logins('team-selection', 'secret'), 1, 'a login-shaped body is imported, trimmed')
; SELECT results_eq('SELECT github_login, github_user_id, github_verified_at FROM data."user" WHERE id = 3', ' VALUES (''kljensen''::text, NULL::bigint, NULL::timestamptz) ', 'attested only: no account id, no verification')
; SELECT "is"(api.import_github_logins('team-selection', 'secret'), 0, 'importing again changes nobody')
; SELECT
    "is"((
        SELECT github_login
        FROM data."user"
        WHERE id = 1
    ), 'alice-renamed', 'an existing login is never overwritten by the import')
; SELECT throws_ok('SELECT api.import_github_logins(''team-selection'', ''nope'')', '22023', NULL, 'an unknown field is refused')
;
-- The imported login is later verified by the service, and a team repository
-- granted to that account then locks it like an individual one.
SET "request.jwt.claim.role" TO app
; SET "request.jwt.claim.user_id" TO ''
; SET "request.jwt.claim.app_name" TO authapp
; SELECT lives_ok('SELECT * FROM api.set_user_github_identity(3, 1003, ''kljensen'', true)', 'the imported login is verified with its account id')
; UPDATE data.assignment_repository
SET provider_user_id = 1003
WHERE
    template_slug = 'project-starter'
    AND team_nickname = 'bright-fog'
; SELECT throws_ok('SELECT * FROM api.set_user_github_identity(3, 1030, ''kljensen-2'', false)', 'P0001', 'github_identity_locked', 'a team repository granted to this account locks it for the team member')
;
-- ---------------------------------------------------------------------------
-- Row-level security on the attempts
-- ---------------------------------------------------------------------------
-- On the board: user 1's exam-1-starter, closed-starter and go-starter
-- attempts, bright-fog's project-starter attempt (user 1 initiated), user
-- 2's exam-1-starter and go-starter attempts.
SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT set_eq('SELECT template_slug || '':'' || coalesce(team_nickname, user_id::text) FROM api.repository_provisionings', ARRAY['exam-1-starter:1', 'closed-starter:1', 'go-starter:1', 'project-starter:bright-fog'], 'a student sees their own attempts and their team''s, and nothing else')
; SET "request.jwt.claim.user_id" TO "2"
; SELECT set_eq('SELECT template_slug || '':'' || coalesce(team_nickname, user_id::text) FROM api.repository_provisionings', ARRAY['exam-1-starter:2', 'go-starter:2'], 'the other student sees only their own')
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT is_empty('SELECT id FROM api.repository_provisionings', 'a ta with no attempts and no team sees none')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.repository_provisionings
    ), 6, 'faculty see every attempt')
; SELECT throws_ok('UPDATE api.repository_provisionings SET stage = ''finalized''', '42501', NULL, 'not even faculty write attempts through the view')
; RESET role
; SELECT *
FROM finish()
