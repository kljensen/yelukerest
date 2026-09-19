-- Self-serve assignment repositories (issue #394): the template configuration
-- on data.assignment, the GitHub identity on data."user", the provisioning
-- attempt and its service RPCs, and who can see and call what.
--
-- Sample data this file leans on: users 1 (abc123, student, team bright-fog),
-- 2 (bde456, student, team hazy-mountain), 3 (klj39, faculty, bright-fog),
-- 4 (jlb325, ta, no team), 5 (crt43, observer); assignments exam-1
-- (individual, open, URL field `url`), project-update-1 (team, open, URL
-- field `repo-url`, and team submission 4 for bright-fog already holding
-- http://github.com/kljensen/fakerepo in it), team-selection (individual,
-- no URL field, submissions 1-3 in field `secret`) and js-koans (draft).
SELECT *
FROM no_plan()
;
-- ---------------------------------------------------------------------------
-- Shape and privileges
-- ---------------------------------------------------------------------------
SELECT has_table('data', 'assignment_repository_provisioning', 'the attempt table exists')
; SELECT view_owner_is('api', 'assignment_repository_provisionings', 'api', 'the attempts view is owned by api, or its policy never applies')
; SELECT table_privs_are('api', 'assignment_repository_provisionings', 'student', ARRAY['SELECT'], 'a student may only read attempts')
; SELECT table_privs_are('api', 'assignment_repository_provisionings', 'ta', ARRAY['SELECT'], 'a ta may only read attempts')
; SELECT table_privs_are('api', 'assignment_repository_provisionings', 'faculty', ARRAY['SELECT'], 'faculty may only read attempts; the service writes them')
; SELECT table_privs_are('data', 'assignment_repository_provisioning', 'faculty', ARRAY[]::text[], 'faculty hold nothing on the base table')
; SELECT function_privs_are('api', 'claim_repository_provisioning', ARRAY['text', 'integer'], 'app', ARRAY['EXECUTE'], 'the service may claim')
; SELECT function_privs_are('api', 'claim_repository_provisioning', ARRAY['text', 'integer'], 'student', ARRAY[]::text[], 'a student may not claim')
; SELECT function_privs_are('api', 'claim_repository_provisioning', ARRAY['text', 'integer'], 'faculty', ARRAY[]::text[], 'faculty may not claim')
; SELECT function_privs_are('api', 'finalize_repository_provisioning', ARRAY['integer', 'text', 'bigint'], 'student', ARRAY[]::text[], 'a student may not finalize')
; SELECT function_privs_are('api', 'set_user_github_identity', ARRAY['integer', 'bigint', 'text', 'boolean'], 'faculty', ARRAY[]::text[], 'faculty may not set a GitHub identity directly')
; SELECT function_privs_are('api', 'import_github_logins', ARRAY['text', 'text'], 'faculty', ARRAY['EXECUTE'], 'faculty may run the login import')
; SELECT function_privs_are('api', 'import_github_logins', ARRAY['text', 'text'], 'app', ARRAY[]::text[], 'the service may not run the login import')
; SELECT function_privs_are('api', 'import_github_logins', ARRAY['text', 'text'], 'student', ARRAY[]::text[], 'a student may not run the login import')
;
-- ---------------------------------------------------------------------------
-- Template configuration: all or nothing, and the field must be a URL field
-- ---------------------------------------------------------------------------
SELECT lives_ok('
        UPDATE data.assignment
        SET repository_template_provider = ''github'',
            repository_template_full_name = ''yale-mgt-656/exam-1-template'',
            repository_url_field_slug = ''url''
        WHERE slug = ''exam-1''
    ', 'an assignment can be configured with all three template columns')
; SELECT throws_ok('
        UPDATE data.assignment
        SET repository_template_provider = ''github''
        WHERE slug = ''team-selection''
    ', '23514', NULL, 'a provider without a template and a field is refused')
; SELECT throws_ok('
        UPDATE data.assignment
        SET repository_template_provider = ''github'',
            repository_template_full_name = ''yale-mgt-656/exam-1-template'',
            repository_url_field_slug = ''repo-url''
        WHERE slug = ''exam-1''
    ', '23503', NULL, 'the URL field must belong to the assignment itself')
; SELECT throws_ok('
        UPDATE data.assignment
        SET repository_template_provider = ''github'',
            repository_template_full_name = ''yale-mgt-656/exam-1-template'',
            repository_url_field_slug = ''profound''
        WHERE slug = ''exam-1''
    ', '23514', NULL, 'the designated field must be a URL field')
; SELECT throws_ok('
        UPDATE data.assignment
        SET repository_template_full_name = ''not a repo''
        WHERE slug = ''exam-1''
    ', '23514', NULL, 'the template must be owner/repo')
; SELECT throws_ok('
        UPDATE data.assignment_field SET is_url = false
        WHERE assignment_slug = ''exam-1'' AND slug = ''url''
    ', '23514', NULL, 'a designated field cannot stop being a URL field')
; SELECT throws_ok('
        DELETE FROM data.assignment_field
        WHERE assignment_slug = ''exam-1'' AND slug = ''url''
    ', '23503', NULL, 'a designated field cannot be deleted from under the configuration')
; SELECT lives_ok('
        UPDATE data.assignment
        SET repository_template_provider = ''github'',
            repository_template_full_name = ''yale-mgt-656/project-template'',
            repository_url_field_slug = ''repo-url''
        WHERE slug = ''project-update-1''
    ', 'a team assignment can be configured too')
;
-- Faculty configure through the existing view; students read it and cannot
-- write it.
SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SET "request.jwt.claim.app_name" TO ''
; SELECT lives_ok('
        UPDATE api.assignments
        SET repository_template_full_name = ''yale-mgt-656/exam-1-starter''
        WHERE slug = ''exam-1''
    ', 'faculty can set the template through api.assignments')
; SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT results_eq('
        SELECT repository_template_provider, repository_template_full_name, repository_url_field_slug
        FROM api.my_assignments WHERE slug = ''exam-1''
    ', ' VALUES (''github''::text, ''yale-mgt-656/exam-1-starter''::text, ''url''::text) ', 'a student reads the template configuration on my_assignments')
; SELECT results_eq('
        SELECT repository_template_provider, repository_template_full_name, repository_url_field_slug
        FROM api.assignments WHERE slug = ''team-selection''
    ', ' VALUES (NULL::text, NULL::text, NULL::text) ', 'an unconfigured assignment reads NULL for all three')
; SELECT throws_ok('
        UPDATE api.assignments
        SET repository_template_full_name = ''evil/template''
        WHERE slug = ''exam-1''
    ', '42501', NULL, 'a student cannot write the template columns')
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
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1'', 1)', '42501', NULL, 'a student holds no EXECUTE on claim')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(1, ''failed'')', '42501', NULL, 'a student holds no EXECUTE on record')
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(1, ''https://github.com/x/y'')', '42501', NULL, 'a student holds no EXECUTE on finalize')
; SELECT throws_ok('SELECT * FROM api.touch_repository_provisioning_readiness(1, true)', '42501', NULL, 'a student holds no EXECUTE on touch')
; SELECT throws_ok('SELECT * FROM api.set_user_github_identity(1, 1, ''x'', true)', '42501', NULL, 'a student holds no EXECUTE on set_user_github_identity')
; SELECT throws_ok('SELECT api.import_github_logins(''team-selection'', ''secret'')', '42501', NULL, 'a student holds no EXECUTE on import_github_logins')
; RESET role
;
-- The function's own check, beneath the grant: a student claim carried by a
-- role that can execute, and the other service, are refused by name.
SELECT throws_like('SELECT * FROM api.claim_repository_provisioning(''exam-1'', 1)', '%insufficient_privilege%', 'claim refuses a student claim inside the function')
; SET "request.jwt.claim.role" TO app
; SET "request.jwt.claim.user_id" TO ''
; SET "request.jwt.claim.app_name" TO mcpapp
; SELECT throws_like('SELECT * FROM api.set_user_github_identity(1, 1001, ''alice-m'', true)', '%insufficient_privilege%', 'mcpapp is not authapp')
; SELECT throws_like('SELECT api.import_github_logins(''team-selection'', ''secret'')', '%insufficient_privilege%', 'the login import is faculty-only, not for the service')
;
-- A service claim with no app_name at all is refused, not waved through: the
-- guard has to fail closed on a NULL claim.
SET "request.jwt.claim.app_name" TO ''
; SELECT throws_like('SELECT * FROM api.claim_repository_provisioning(''exam-1'', 1)', '%insufficient_privilege%', 'claim refuses role app without an app_name')
; SELECT throws_like('SELECT * FROM api.record_repository_provisioning(1, ''failed'', NULL, NULL, ''x'')', '%insufficient_privilege%', 'record refuses role app without an app_name')
; SELECT throws_like('SELECT * FROM api.finalize_repository_provisioning(1, ''https://github.com/x/y'')', '%insufficient_privilege%', 'finalize refuses role app without an app_name')
; SELECT throws_like('SELECT * FROM api.touch_repository_provisioning_readiness(1, true)', '%insufficient_privilege%', 'touch refuses role app without an app_name')
; SELECT throws_like('SELECT * FROM api.set_user_github_identity(1, 1001, ''alice-m'', true)', '%insufficient_privilege%', 'set_user_github_identity refuses role app without an app_name')
;
-- ---------------------------------------------------------------------------
-- Claim, as authapp
-- ---------------------------------------------------------------------------
SET "request.jwt.claim.app_name" TO authapp
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''team-selection'', 1)', 'P0001', 'repository_not_configured', 'an assignment without a template cannot be claimed')
; UPDATE data.assignment
SET
    repository_template_provider = 'github',
    repository_template_full_name = 'yale-mgt-656/koans-template',
    repository_url_field_slug = 'repo-url'
WHERE slug = 'js-koans'
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''js-koans'', 1)', 'P0001', 'repository_not_configured', 'a draft reads as not configured')
; UPDATE data."user"
SET team_nickname = NULL
WHERE id = 2
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''project-update-1'', 2)', 'P0001', 'no_team', 'a team assignment needs the student on a team')
; UPDATE data."user"
SET team_nickname = 'hazy-mountain'
WHERE id = 2
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1'', 4)', 'P0001', 'not_a_student', 'a ta cannot claim a repository')
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1'', 3)', 'P0001', 'not_a_student', 'nor can faculty')
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1'', 2)', 'P0001', 'needs_github_link', 'an individual assignment needs the student''s GitHub login')
;
-- Closed for the owner, unless an extension reopens it.
INSERT INTO data.assignment (slug, points_possible, is_draft, is_team, title, body, closed_at, repository_template_provider, repository_template_full_name, repository_url_field_slug)
VALUES ('zz-closed', 10, false, false, 'Closed', 'b', current_timestamp - '1 day'::interval, NULL, NULL, NULL)
; INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder, is_url, is_multiline, example)
VALUES ('url', 'zz-closed', 'l', 'h', 'p', true, false, 'https://github.com/x')
; UPDATE data.assignment
SET
    repository_template_provider = 'github',
    repository_template_full_name = 'yale-mgt-656/closed-template',
    repository_url_field_slug = 'url'
WHERE slug = 'zz-closed'
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''zz-closed'', 1)', 'P0001', 'assignment_closed', 'a closed assignment cannot be claimed')
; INSERT INTO data.assignment_grade_exception (assignment_slug, user_id, closed_at, fractional_credit)
VALUES ('zz-closed', 1, current_timestamp + '7 days'::interval, 1)
; SELECT
    "is"((
        SELECT stage
        FROM api.claim_repository_provisioning('zz-closed', 1)
    ), 'claimed', 'an extension reopens the assignment for its holder')
; SELECT throws_ok('SELECT * FROM api.claim_repository_provisioning(''zz-closed'', 2)', 'P0001', 'assignment_closed', 'and for nobody else')
;
-- A fresh claim.
SELECT results_eq('
        SELECT assignment_slug, is_team, user_id, team_nickname, initiated_by_user_id,
               provider, template_full_name, destination_name, provider_repo_id, stage,
               error_code, existing_repository_id
        FROM api.claim_repository_provisioning(''exam-1'', 1)
    ', ' VALUES (''exam-1''::text, false, 1, NULL::text, 1, ''github''::text, ''yale-mgt-656/exam-1-starter''::text,
                 ''exam-1-alice-m''::text, NULL::bigint, ''claimed''::text, NULL::text, NULL::int) ', 'a fresh claim creates an attempt named after the assignment and the login')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.assignment_repository_provisioning
        WHERE
            assignment_slug = 'exam-1'
            AND user_id = 1
    ), 1, 'one attempt row was written')
; SELECT
    "is"((
        SELECT count(DISTINCT id)::int
        FROM
            (
                (
                    SELECT id
                    FROM api.claim_repository_provisioning('exam-1', 1)
                    UNION ALL
                    SELECT id
                    FROM api.claim_repository_provisioning('exam-1', 1)
                )
                UNION ALL
                SELECT id
                FROM data.assignment_repository_provisioning
                WHERE
                    assignment_slug = 'exam-1'
                    AND user_id = 1
            ) ids
    ), 1, 'claiming again resumes the same attempt')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.assignment_repository_provisioning
    ), 2, 'no second attempt was created')
;
-- ---------------------------------------------------------------------------
-- Record: the transitions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION zapadka_test.attempt(p_slug text, p_user int) RETURNS int LANGUAGE sql STABLE AS $$
    SELECT id FROM data.assignment_repository_provisioning WHERE assignment_slug = p_slug AND user_id = p_user
$$
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''granted'')', 'P0001', 'invalid_stage_transition', 'claimed cannot jump to granted')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''finalized'')', 'P0001', 'invalid_stage_transition', 'finalized is reached through finalize, not record')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''generated'')', '22023', NULL, 'generated needs the forge id and name')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''bogus'')', 'P0001', 'invalid_stage_transition', 'an unknown stage is refused')
; SELECT results_eq('
        SELECT stage, provider_repo_id, provider_full_name
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''generated'', 500001, ''yale-mgt-656/exam-1-alice-m'')
    ', ' VALUES (''generated''::text, 500001::bigint, ''yale-mgt-656/exam-1-alice-m''::text) ', 'claimed becomes generated with the repository the forge returned')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''claimed'')', 'P0001', 'invalid_stage_transition', 'generated cannot go back to claimed')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''generated'', 500009, ''yale-mgt-656/exam-1-alice-m'')', 'P0001', 'invalid_stage_transition', 'a repeated generated naming a different repository is refused')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''granted'', 500001, ''yale-mgt-656/exam-1-alice-m'')', '22023', NULL, 'a repository is recorded on generated only')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''failed'')', '22023', NULL, 'a failure needs an error code')
; SELECT results_eq('
        SELECT stage, error_code, provider_repo_id
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''failed'', NULL, NULL, ''github_timeout'')
    ', ' VALUES (''failed''::text, ''github_timeout''::text, 500001::bigint) ', 'any unfinalized stage can fail, with a code, keeping what the forge said')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''failed'', NULL, NULL, ''GitHub said: 502 Bad Gateway'')', '23514', NULL, 'an error code is a stable token, never a raw forge message')
; SELECT results_eq('
        SELECT stage, error_code
        FROM api.claim_repository_provisioning(''exam-1'', 1)
    ', ' VALUES (''claimed''::text, NULL::text) ', 'claiming a failed attempt resets it to claimed')
; SELECT results_eq('
        SELECT stage
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''generated'', 500001, ''yale-mgt-656/exam-1-alice-m'')
    ', ' VALUES (''generated''::text) ', 'the reset attempt moves forward again')
; SELECT results_eq('
        SELECT stage
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''generated'', 500001, ''yale-mgt-656/exam-1-alice-m'')
    ', ' VALUES (''generated''::text) ', 'recording the same stage again is a harmless repeat')
; SELECT results_eq('
        SELECT stage
        FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''granted'')
    ', ' VALUES (''granted''::text) ', 'generated becomes granted')
;
-- ---------------------------------------------------------------------------
-- Readiness
-- ---------------------------------------------------------------------------
SELECT throws_ok('SELECT * FROM api.touch_repository_provisioning_readiness(zapadka_test.attempt(''zz-closed'', 1), true)', 'P0001', 'invalid_stage_transition', 'a claimed attempt has no repository to check')
; SELECT results_eq('
        SELECT last_checked_at IS NOT NULL, ready_at
        FROM api.touch_repository_provisioning_readiness(zapadka_test.attempt(''exam-1'', 1), false)
    ', ' VALUES (true, NULL::timestamptz) ', 'a check that found nothing ready records the check only')
; SELECT
    ok((
        SELECT ready_at IS NOT NULL
        FROM api.touch_repository_provisioning_readiness(zapadka_test.attempt('exam-1', 1), true)
    ), 'a ready check sets ready_at')
; SELECT
    "is"((
        SELECT count(DISTINCT ready_at)::int
        FROM
            (
                SELECT ready_at
                FROM api.touch_repository_provisioning_readiness(zapadka_test.attempt('exam-1', 1), true)
                UNION ALL
                SELECT ready_at
                FROM data.assignment_repository_provisioning
                WHERE id = zapadka_test.attempt('exam-1', 1)
            ) t
    ), 1, 'ready_at is set once and never moved')
;
-- ---------------------------------------------------------------------------
-- Finalize: three records in one call, or none
-- ---------------------------------------------------------------------------
-- Tighten the field's pattern so the pattern branch is real.
UPDATE data.assignment_field
SET pattern = E'https://github\\.com/.*'
WHERE
    assignment_slug = 'exam-1'
    AND slug = 'url'
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''not a url'')', 'P0001', 'repo_url_mismatch', 'a body that is not the repository''s URL is refused')
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''https://github.com/yale-mgt-656/somebody-elses-repo'')', 'P0001', 'repo_url_mismatch', 'the URL is bound to the repository generate recorded')
;
-- A pattern the bound URL cannot satisfy, then back.
UPDATE data.assignment_field
SET
    pattern = E'https://gitlab\\.com/.*',
    example = 'https://gitlab.com/foo'
WHERE
    assignment_slug = 'exam-1'
    AND slug = 'url'
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''https://github.com/yale-mgt-656/exam-1-alice-m'')', 'P0001', 'url_pattern_mismatch', 'a URL outside the field''s pattern is refused')
; UPDATE data.assignment_field
SET
    pattern = E'https://github\\.com/.*',
    example = 'https://github.com/foo'
WHERE
    assignment_slug = 'exam-1'
    AND slug = 'url'
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''https://github.com/yale-mgt-656/exam-1-alice-m'', 9999)', 'P0001', 'github_identity_mismatch', 'the account the repository was granted to must be the one the student linked')
; SELECT is_empty('SELECT 1 FROM data.assignment_submission WHERE assignment_slug = ''exam-1'' AND user_id = 1', 'a refused finalize wrote no submission')
; SELECT results_eq('
        SELECT assignment_slug, is_team, user_id, provider, provider_repo_id, provider_full_name, provider_user_id
        FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''https://github.com/yale-mgt-656/exam-1-alice-m'', 1001)
    ', ' VALUES (''exam-1''::text, false, 1, ''github''::text, 500001::bigint, ''yale-mgt-656/exam-1-alice-m''::text, 1001::bigint) ', 'finalize records the repository')
; SELECT results_eq('
        SELECT s.submitter_user_id AS submission_submitter, fs.body, fs.origin, fs.submitter_user_id AS field_submitter,
               (SELECT count(*)::int FROM data.assignment_submission_participant p WHERE p.assignment_submission_id = s.id AND p.user_id = 1)
        FROM data.assignment_submission s
        JOIN data.assignment_field_submission fs ON fs.assignment_submission_id = s.id
        WHERE s.assignment_slug = ''exam-1'' AND s.user_id = 1
    ', ' VALUES (1, ''https://github.com/yale-mgt-656/exam-1-alice-m''::text, ''provisioning''::text, 1, 1) ', 'and the submission, its participant snapshot, and the URL field with origin provisioning')
; SELECT
    "is"((
        SELECT stage
        FROM data.assignment_repository_provisioning
        WHERE id = zapadka_test.attempt('exam-1', 1)
    ), 'finalized', 'the attempt is finalized')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.assignment_field_submission_event
        WHERE
            assignment_slug = 'exam-1'
            AND assignment_field_slug = 'url'
            AND origin = 'provisioning'
    ), 1, 'the history records one submitted event with origin provisioning')
; SELECT results_eq('
        SELECT provider_repo_id
        FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''https://github.com/yale-mgt-656/exam-1-alice-m'', 1001)
    ', ' VALUES (500001::bigint) ', 'finalizing again returns the repository and changes nothing')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.assignment_field_submission_event
        WHERE
            assignment_slug = 'exam-1'
            AND assignment_field_slug = 'url'
    ), 1, 'a repeated finalize appends no history')
; SELECT throws_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 1), ''failed'', NULL, NULL, ''late'')', 'P0001', 'already_finalized', 'a finalized attempt is immutable')
; SELECT results_eq('
        SELECT id = zapadka_test.attempt(''exam-1'', 1) AS same_attempt, stage, provider_repo_id, existing_repository_id IS NOT NULL AS has_repository
        FROM api.claim_repository_provisioning(''exam-1'', 1)
    ', ' VALUES (true, ''finalized''::text, 500001::bigint, true) ', 'claiming after finalize returns the finalized row with the repository')
;
-- A repository the old course tooling recorded, with no attempt at all: it
-- answers the claim before the login or the deadline is looked at.
INSERT INTO data.assignment_repository (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
VALUES ('zz-closed', false, 2, 500004, 'yale-mgt-656/zz-closed-bob')
; SELECT results_eq('
        SELECT id, stage, provider_full_name, destination_name, existing_repository_id IS NOT NULL
        FROM api.claim_repository_provisioning(''zz-closed'', 2)
    ', ' VALUES (NULL::int, ''finalized''::text, ''yale-mgt-656/zz-closed-bob''::text, ''zz-closed-bob''::text, true) ', 'an existing repository answers a claim without an attempt, even for a student with no login on a closed assignment')
;
-- A team attempt whose field already holds the student's own value.
SELECT results_eq('
        SELECT is_team, team_nickname, initiated_by_user_id, destination_name
        FROM api.claim_repository_provisioning(''project-update-1'', 1)
    ', ' VALUES (true, ''bright-fog''::text, 1, ''project-update-1-bright-fog''::text) ', 'a team claim names the team')
; CREATE OR REPLACE FUNCTION zapadka_test.team_attempt(p_slug text, p_team text) RETURNS int LANGUAGE sql STABLE AS $$
    SELECT id FROM data.assignment_repository_provisioning WHERE assignment_slug = p_slug AND team_nickname = p_team
$$
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.team_attempt(''project-update-1'', ''bright-fog''), ''https://github.com/yale-mgt-656/project-update-1-bright-fog'')', 'P0001', 'invalid_stage_transition', 'only a granted attempt can be finalized')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.team_attempt(''project-update-1'', ''bright-fog''), ''generated'', 500002, ''yale-mgt-656/project-update-1-bright-fog'')', 'the team attempt is generated')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.team_attempt(''project-update-1'', ''bright-fog''), ''granted'')', 'and granted')
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.team_attempt(''project-update-1'', ''bright-fog''), ''https://github.com/yale-mgt-656/project-update-1-bright-fog'')', 'P0001', 'submission_conflict', 'a different URL already in the field is a conflict, not an overwrite')
; SELECT is_empty('SELECT 1 FROM data.assignment_repository WHERE assignment_slug = ''project-update-1''', 'the refused finalize left no repository row behind')
; SELECT
    "is"((
        SELECT stage
        FROM data.assignment_repository_provisioning
        WHERE id = zapadka_test.team_attempt('project-update-1', 'bright-fog')
    ), 'granted', 'and the attempt is still granted')
; SELECT
    "is"((
        SELECT body
        FROM data.assignment_field_submission
        WHERE
            assignment_submission_id = 4
            AND assignment_field_slug = 'repo-url'
    ), 'http://github.com/kljensen/fakerepo', 'the student''s value is untouched')
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.team_attempt(''project-update-1'', ''bright-fog''), ''http://github.com/kljensen/fakerepo'')', 'P0001', 'repo_url_mismatch', 'and the student''s value cannot be passed off as the repository''s URL')
;
-- The team fixes its own field to the provisioned repository; finalize then
-- finds an identical value and leaves it alone.
UPDATE data.assignment_field_submission
SET body = 'https://github.com/yale-mgt-656/project-update-1-bright-fog'
WHERE
    assignment_submission_id = 4
    AND assignment_field_slug = 'repo-url'
; SELECT results_eq('
        SELECT team_nickname, provider_repo_id
        FROM api.finalize_repository_provisioning(zapadka_test.team_attempt(''project-update-1'', ''bright-fog''), ''https://github.com/yale-mgt-656/project-update-1-bright-fog'')
    ', ' VALUES (''bright-fog''::text, 500002::bigint) ', 'an identical URL already in the field is a no-op and finalize completes')
; SELECT
    "is"((
        SELECT count(*)::int
        FROM data.assignment_submission
        WHERE
            assignment_slug = 'project-update-1'
            AND team_nickname = 'bright-fog'
    ), 1, 'the existing team submission was reused, not duplicated')
;
-- A different repository already recorded for the owner.
SELECT lives_ok('SELECT * FROM api.set_user_github_identity(2, 1002, ''bob-f'', false)', 'user 2 links an account')
; SELECT lives_ok('SELECT * FROM api.claim_repository_provisioning(''exam-1'', 2)', 'user 2 claims exam-1')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 2), ''generated'', 600001, ''yale-mgt-656/exam-1-bob'')', 'generated')
; SELECT lives_ok('SELECT * FROM api.record_repository_provisioning(zapadka_test.attempt(''exam-1'', 2), ''granted'')', 'granted')
; INSERT INTO data.assignment_repository (assignment_slug, is_team, user_id, provider_repo_id, provider_full_name)
VALUES ('exam-1', false, 2, 600002, 'yale-mgt-656/exam-1-bob-by-hand')
; SELECT throws_ok('SELECT * FROM api.finalize_repository_provisioning(zapadka_test.attempt(''exam-1'', 2), ''https://github.com/yale-mgt-656/exam-1-bob'')', 'P0001', 'repository_conflict', 'a different repository already on record for the owner is a conflict')
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
    assignment_slug = 'project-update-1'
    AND team_nickname = 'bright-fog'
; SELECT throws_ok('SELECT * FROM api.set_user_github_identity(3, 1030, ''kljensen-2'', false)', 'P0001', 'github_identity_locked', 'a team repository granted to this account locks it for the team member')
;
-- ---------------------------------------------------------------------------
-- Row-level security on the attempts
-- ---------------------------------------------------------------------------
-- On the board: user 1's exam-1 and zz-closed attempts, bright-fog's
-- project-update-1 attempt (user 1 initiated), user 2's exam-1 attempt.
SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT set_eq('SELECT assignment_slug || '':'' || coalesce(team_nickname, user_id::text) FROM api.assignment_repository_provisionings', ARRAY['exam-1:1', 'zz-closed:1', 'project-update-1:bright-fog'], 'a student sees their own attempts and their team''s, and nothing else')
; SET "request.jwt.claim.user_id" TO "2"
; SELECT set_eq('SELECT assignment_slug || '':'' || coalesce(team_nickname, user_id::text) FROM api.assignment_repository_provisionings', ARRAY['exam-1:2'], 'the other student sees only their own')
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT is_empty('SELECT id FROM api.assignment_repository_provisionings', 'a ta with no attempts and no team sees none')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT
    "is"((
        SELECT count(*)::int
        FROM api.assignment_repository_provisionings
    ), 4, 'faculty see every attempt')
; SELECT throws_ok('UPDATE api.assignment_repository_provisionings SET stage = ''finalized''', '42501', NULL, 'not even faculty write attempts through the view')
; RESET role
; SELECT *
FROM finish()
