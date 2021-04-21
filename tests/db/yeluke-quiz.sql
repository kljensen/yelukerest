begin;
select plan(10);

SELECT view_owner_is(
    'api', 'quizzes', 'api',
    'api.quizzes view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'quizzes', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.quizzes"'
);

SELECT table_privs_are(
    'api', 'quizzes', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.quizzes"'
);

SELECT table_privs_are(
    'data', 'quiz', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_ok(
    'select (meeting_slug) from api.quizzes',
    '42501',
    'permission denied for view quizzes',
    'anonymous users should not be able to use the api.quizzes view'
);

set local role student;
set request.jwt.claim.role = 'student';

SELECT set_eq(
    'SELECT meeting_slug FROM api.quizzes ORDER BY (meeting_slug)',
    ARRAY['intro', 'structuredquerylang', 'entrepreneurship-woot'],
    'students should be able to select from the api.quizzes view'
);

PREPARE doinsert AS INSERT INTO api.quizzes (meeting_slug, points_possible, is_draft, duration, open_at, closed_at, created_at, updated_at) VALUES ('server-side-apps', 2, false, '00:10:00', '2017-01-04 07:55:50+00', '2017-01-06 07:55:50+00', '2018-01-06 07:55:50+00', '2018-01-06 13:10:23.24505+00');

SELECT throws_ok(
    'doinsert',
    '42501',
    'permission denied for view quizzes',
    'students should not be able to insert'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT lives_ok(
    'doinsert',
    'faculty should be able to insert'
);

SELECT lives_ok(
    'DELETE FROM api.quizzes WHERE meeting_slug = ''server-side-apps''',
    'faculty can delete quizzes'
);

SELECT lives_ok(
    'INSERT INTO api.quizzes (meeting_slug, points_possible, duration) VALUES (''server-side-apps'', 13, ''10 minutes'')',
    'triggers fill in default values for quizzes'
);


-- set request.jwt.claim.user_id = '1';

-- SELECT set_eq(
--     'SELECT user_id FROM api.quizzes ORDER BY (meeting_slug, user_id)',
--     ARRAY[1, 1, 1],
--     'students should only be able to see their own rows in the api.quizzes view'
-- );

select * from finish();
rollback;
