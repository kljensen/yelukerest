begin;
select plan(24);

SELECT set_eq(
    $$
        SELECT c.relname || '.' || t.tgname
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'data'
        AND NOT t.tgisinternal
    $$,
    ARRAY[
        'artifact.tg_artifact_default',
        'assignment.tg_assignment_default',
        'assignment_field.tg_assignment_field_default',
        'assignment_field_submission.tg_assignment_field_submission_default',
        'assignment_grade.tg_assignment_grade_default',
        'assignment_grade_exception.tg_assignment_grade_exception_default',
        'assignment_submission.tg_assignment_submission_default',
        'assignment_submission.tg_assignment_submission_participants',
        'engagement.tg_engagement_update_timestamps',
        'grade.tg_grade_default',
        'grade_snapshot.tg_grade_snapshot_default',
        'meeting.tg_meeting_default',
        'quiz.tg_quiz_default',
        'quiz_grade.tg_quiz_grade_default',
        'quiz_grade_exception.tg_quiz_grade_exception_default',
        'quiz_submission.tg_quiz_submission_default',
        'team.tg_team_update_timestamps',
        'ui_element.tg_ui_element_update_timestamps',
        'user.tg_users_default',
        'user_secret.tg_user_secret_default'
    ],
    'all data triggers are intentionally covered by runtime tests'
);

SELECT set_eq(
    $$
        SELECT p.proname::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.proname IN (
            'fill_assignment_grade_defaults',
            'fill_assignment_grade_exception_defaults',
            'fill_assignment_submission_defaults',
            'fill_quiz_grade_defaults',
            'quiz_set_defaults'
        )
        AND p.prosecdef
        AND p.proconfig @> ARRAY['search_path=data, pg_temp']
    $$,
    ARRAY[
        'fill_assignment_grade_defaults',
        'fill_assignment_grade_exception_defaults',
        'fill_assignment_submission_defaults',
        'fill_quiz_grade_defaults',
        'quiz_set_defaults'
    ],
    'data lookup trigger functions run as security definers with pinned search_path'
);

SELECT results_eq(
    $$
        INSERT INTO data."user" (email, netid, nickname, role)
        VALUES ('MIXEDCASE@YALE.EDU', 'ABC999', 'LOUD-NICK', 'student')
        RETURNING email, netid, nickname, updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES ('mixedcase@yale.edu'::text, 'abc999'::text, 'loud-nick'::text, true) $$,
    'tg_users_default lowercases user fields and refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.team SET nickname = nickname WHERE nickname = 'damp-pond' RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_team_update_timestamps refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.meeting SET title = title WHERE slug = 'intro' RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_meeting_default refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.engagement SET participation = participation WHERE user_id = 1 AND meeting_slug = 'intro' RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_engagement_update_timestamps refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.ui_element SET body = body WHERE key = 'course-name' RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_ui_element_update_timestamps refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.assignment SET body = body WHERE slug = 'team-selection' RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_assignment_default refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.assignment_field SET help = help WHERE slug = 'secret' AND assignment_slug = 'team-selection' RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_assignment_field_default refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.artifact SET title = title WHERE id = 1 RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_artifact_default refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.user_secret SET body = body WHERE slug = 'foo' AND user_id = 1 RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_user_secret_default refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.grade_snapshot SET description = description WHERE slug = 'after-first-exam' RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_grade_snapshot_default refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.grade SET description = description WHERE snapshot_slug = 'after-first-exam' AND user_id = 1 RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_grade_default refreshes updated_at'
);

SELECT results_eq(
    $$ UPDATE data.quiz_grade_exception SET fractional_credit = fractional_credit WHERE quiz_id = 1 AND user_id = 5 RETURNING updated_at > '2020-01-01'::timestamptz $$,
    ARRAY[true],
    'tg_quiz_grade_exception_default refreshes updated_at'
);

SELECT results_eq(
    $$
        INSERT INTO data.assignment_grade_exception (assignment_slug, user_id, closed_at)
        VALUES ('team-selection', 4, current_timestamp + '1 hour'::interval)
        RETURNING is_team, updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES (false, true) $$,
    'tg_assignment_grade_exception_default fills is_team and refreshes updated_at'
);

SELECT results_eq(
    $$
        INSERT INTO data.quiz (meeting_slug, points_possible, is_draft, duration)
        VALUES ('server-side-apps', 7, false, '10 minutes'::interval)
        RETURNING
            open_at = (
                SELECT begins_at - '5 days'::interval
                FROM data.meeting
                WHERE slug = 'server-side-apps'
            ),
            closed_at = (
                SELECT begins_at
                FROM data.meeting
                WHERE slug = 'server-side-apps'
            ),
            updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES (true, true, true) $$,
    'tg_quiz_default fills open_at and closed_at from the meeting'
);

SET LOCAL request.jwt.claim.user_id = '5';

SELECT results_eq(
    $$
        INSERT INTO data.quiz_submission (quiz_id)
        VALUES (2)
        RETURNING user_id, updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES (5, true) $$,
    'tg_quiz_submission_default fills user_id from request context'
);

SELECT results_eq(
    $$
        INSERT INTO data.quiz_grade (quiz_id, points)
        VALUES (2, 3)
        RETURNING user_id, points_possible, updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES (5, 13::smallint, true) $$,
    'tg_quiz_grade_default fills user_id and points_possible'
);

SELECT results_eq(
    $$
        INSERT INTO data.assignment_submission (assignment_slug)
        VALUES ('team-selection')
        RETURNING is_team, user_id, submitter_user_id, updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES (false, 5, 5, true) $$,
    'tg_assignment_submission_default fills individual submission defaults'
);

SET LOCAL request.jwt.claim.user_id = '2';

SELECT results_eq(
    $$
        INSERT INTO data.assignment_submission (assignment_slug)
        VALUES ('project-update-1')
        RETURNING is_team, user_id, team_nickname, submitter_user_id, updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES (true, NULL::integer, 'hazy-mountain'::text, 2, true) $$,
    'tg_assignment_submission_default fills team submission defaults'
);

SELECT results_eq(
    $$
        SELECT count(*)::integer
        FROM data.assignment_submission_participant p
        JOIN data.assignment_submission s ON s.id = p.assignment_submission_id
        WHERE s.assignment_slug = 'project-update-1'
        AND s.team_nickname = 'hazy-mountain'
        AND p.user_id = 2
    $$,
    ARRAY[1],
    'tg_assignment_submission_participants snapshots team participants'
);

SET LOCAL request.jwt.claim.user_id = '5';

SELECT results_eq(
    $$
        INSERT INTO data.assignment_field_submission (
            assignment_submission_id,
            assignment_field_slug,
            body
        )
        SELECT id, 'secret', 'trigger-secret'
        FROM data.assignment_submission
        WHERE assignment_slug = 'team-selection'
        AND user_id = 5
        RETURNING
            assignment_slug,
            assignment_field_is_url,
            assignment_field_pattern,
            submitter_user_id,
            updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES ('team-selection'::text, false, '.*'::text, 5, true) $$,
    'tg_assignment_field_submission_default fills field metadata from submission id'
);

SET LOCAL request.jwt.claim.user_id = '4';

INSERT INTO data.assignment_submission (assignment_slug)
VALUES ('team-selection');

SELECT results_eq(
    $$
        INSERT INTO data.assignment_field_submission (
            assignment_slug,
            assignment_field_slug,
            body
        )
        VALUES ('team-selection', 'secret', 'slug-filled-secret')
        RETURNING
            assignment_submission_id = (
                SELECT id
                FROM data.assignment_submission
                WHERE assignment_slug = 'team-selection'
                AND user_id = 4
            ),
            submitter_user_id,
            updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES (true, 4, true) $$,
    'tg_assignment_field_submission_default fills submission id from assignment slug and request user'
);

SELECT results_eq(
    $$
        INSERT INTO data.assignment_grade (assignment_submission_id, points)
        SELECT id, 41
        FROM data.assignment_submission
        WHERE assignment_slug = 'team-selection'
        AND user_id = 5
        RETURNING assignment_slug, points_possible, updated_at > '2020-01-01'::timestamptz
    $$,
    $$ VALUES ('team-selection'::text, 50::smallint, true) $$,
    'tg_assignment_grade_default fills assignment_slug and points_possible'
);

select * from finish();
rollback;
