begin;
select plan(4);

SELECT schema_privs_are(
    'api', 'student', ARRAY['USAGE'],
    'authenticated users should have usage privilege of the api schema'
);


-- switch to a anonymous application user
set local role anonymous;
set request.jwt.claim.role = 'anonymous';

select set_eq(
    'select id from api.todos',
    array[ 1, 3, 6 ],
    'only public todos are visible to anonymous users'
);


-- switch to a specific application user
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1'; --alice

select set_eq(
    'select id from api.todos where mine = true',
    array[ 1, 2, 3 ],
    'can see all his todos'
);

select set_eq(
    'select id from api.todos',
    array[ 1, 2, 3, 6 ],
    'can see his todos and public ones'
);



select * from finish();
rollback;
