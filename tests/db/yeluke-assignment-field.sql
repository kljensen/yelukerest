begin;
select plan(14);

SELECT view_owner_is(
    'api', 'assignment_fields', 'api',
    'api.assignment_fields view should be owned by the api role'
);

SELECT table_privs_are(
    'api', 'assignment_fields', 'student', ARRAY['SELECT'],
    'student should only be granted SELECT on view "api.assignment_fields"'
);

SELECT table_privs_are(
    'api', 'assignment_fields', 'faculty', ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE'],
    'faculty should only be granted select, insert, update, delete on view "api.assignment_fields"'
);

SELECT table_privs_are(
    'data', 'quiz', 'faculty', ARRAY[]::text[],
    'faculty should only be granted nothing on "data.quiz"'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_like(
    'select * from api.assignment_fields',
    '%permission denied%',
    'anonymous users should not be able to use the api.assignment_fields view'
);

set local role student;
set request.jwt.claim.role = 'student';

SELECT set_eq(
    'SELECT assignment_slug FROM api.assignment_fields ORDER BY (assignment_slug)',
    ARRAY['exam-1','exam-1', 'js-koans', 'project-update-1', 'project-update-1', 'team-selection'],
    'students should be able to select from the api.assignment_fields view'
);

PREPARE doinsert AS INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder) VALUES ('exam-1', 'myfieldslug', 'gobblygook', 'find this online', 'e.g. kljensen');

SELECT throws_like(
    'doinsert',
    '%permission denied%',
    'students should not be able to insert'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT lives_ok(
    'doinsert',
    'faculty should be able to insert'
);

SELECT lives_ok(
    'DELETE FROM api.assignment_fields WHERE label = ''gobblygook''',
    'faculty can delete assignment_fields'
);

SELECT throws_like(
    $$
        INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,pattern) VALUES ('exam-1', 'myfieldslug', 'gobblygook', 'find this online', 'e.g. kljensen', 'foo.*')
    $$,
    '%violates check constraint%',
    'if a pattern is provided, an example must be provided'
);

SELECT throws_like(
    $$
        INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,pattern,example) VALUES ('exam-1', 'myfieldslug', 'gobblygook', 'find this online', 'e.g. kljensen', 'foo.*', 'bar')
    $$,
    '%violates check constraint%',
    'if a pattern is provided, an example must match it (negative case)'
);

SELECT lives_ok(
    $$
        INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,pattern,example) VALUES ('exam-1', 'myfieldslug', 'gobblygook', 'find this online', 'e.g. kljensen', 'foo.*', 'foobar')
    $$,
    'if a pattern is provided, an example must match it (positive case)'
);

SELECT throws_like(
    $$
        INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,pattern,example) VALUES ('exam-1', 'myfieldslug', 'gobblygook', 'find this online', 'e.g. kljensen', 'foo.*', 'xfoobar')
    $$,
    '%violates check constraint%',
    'patterns are anchored to front and back, so "foo.*" does not match "xfoobar"'
);

SELECT lives_ok(
    $$
        INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,pattern,example) VALUES ('exam-1', 'myfieldslug2', 'gobblygook', 'find this online', 'e.g. kljensen', '.*foo.*', 'xfoobar')
    $$,
    'patterns are anchored to front and back, so ".*foo.*" does not match "xfoobar"'
);

select * from finish();
rollback;
