begin;
select plan(10);

SELECT view_owner_is(
    'api', 'engagements', 'api',
    'api.engagements view should be owned by the api role'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_ok(
    'select (user_id, meeting_slug) from api.engagements',
    '42501',
    'permission denied for view engagements',
    'anonymous users should not be able to use the api.engagements view'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT lives_ok(
    'select (user_id, meeting_slug) from api.engagements',
    'faculty should be able to select from the api.engagements view'
);

SELECT set_eq(
    'SELECT user_id FROM api.engagements ORDER BY (meeting_slug, user_id)',
    ARRAY[1, 2, 3, 1, 2, 3, 1, 2, 3],
    'faculty should be able to select from the api.engagements view'
);

SELECT lives_ok(
    $$ INSERT INTO api.engagements (user_id, meeting_slug, participation) VALUES (5, 'intro', 'led') $$,
    'faculty should be able to insert into the api.engagements view'
);

RESET ROLE;
INSERT INTO data."user" (id, email, netid, nickname, role)
VALUES (6, 'student6@yale.edu', 'stu6', 'quiet-river', 'student');

SELECT results_eq(
    $$
        SELECT meeting_slug, participation
        FROM data.engagement
        WHERE user_id = 6
        ORDER BY meeting_slug
    $$,
    $$VALUES
        ('entrepreneurship-woot'::text, 'absent'::data.participation_enum),
        ('intro'::text, 'absent'::data.participation_enum),
        ('server-side-apps'::text, 'absent'::data.participation_enum),
        ('structuredquerylang'::text, 'absent'::data.participation_enum)
    $$,
    'new students should get absent engagement rows for all meetings'
);

UPDATE data.engagement
SET participation = 'attended'
WHERE user_id = 6
AND meeting_slug = 'intro';

UPDATE data."user" SET role = 'student' WHERE id = 6;

SELECT results_eq(
    $$
        SELECT meeting_slug, participation
        FROM data.engagement
        WHERE user_id = 6
        ORDER BY meeting_slug
    $$,
    $$VALUES
        ('entrepreneurship-woot'::text, 'absent'::data.participation_enum),
        ('intro'::text, 'attended'::data.participation_enum),
        ('server-side-apps'::text, 'absent'::data.participation_enum),
        ('structuredquerylang'::text, 'absent'::data.participation_enum)
    $$,
    'student engagement row maintenance should not overwrite existing attendance'
);

UPDATE data."user" SET role = 'student' WHERE id = 5;

SELECT is(
    (
        SELECT count(*)::int
        FROM data.engagement
        WHERE user_id = 5
    ),
    4,
    'users updated into the student role should get missing engagement rows'
);

SELECT is(
    (
        SELECT count(*)::int
        FROM data.engagement
        WHERE user_id = 4
    ),
    0,
    'non-student users should not get automatic engagement rows'
);

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';

SELECT set_eq(
    'SELECT user_id FROM api.engagements ORDER BY (meeting_slug, user_id)',
    ARRAY[1, 1, 1],
    'students should only be able to see their own rows in the api.engagements view'
);

select * from finish();
rollback;
