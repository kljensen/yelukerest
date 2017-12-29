begin;
select plan(7);

SELECT view_owner_is(
    'api', 'teams', 'api',
    'api.teams view should be owned by the api role'
);

-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

SELECT throws_ok(
    'select nickname from api.teams',
    '42501',
    'permission denied for relation teams',
    'anonymous users should not be able to use the api.teams view'
);

set local role faculty;
set request.jwt.claim.role = 'faculty';

SELECT lives_ok(
    'select nickname from api.teams',
    'faculty should be able to select from the api.teams view'
);

SELECT set_eq(
    'SELECT nickname FROM api.teams',
    ARRAY['bright-fog', 'damp-pond', 'hazy-mountain'],
    'faculty should be able to select from the api.teams view'
);

SELECT lives_ok(
    'UPDATE api.users SET team_nickname = ''bright-fog'' WHERE id=1',
    'faculty should be able to add students to a team'
);

SELECT set_eq(
    'SELECT team_nickname FROM api.users WHERE id=1',
    ARRAY['bright-fog'],
    'faculty should be able to add students to a team (CHECKING RESULT)'
);


set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';


SELECT set_eq(
    'SELECT nickname FROM api.teams',
    ARRAY['bright-fog'],
    'students should only be able to see their own team in the api.teams view'
);

select * from finish();
rollback;
