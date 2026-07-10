begin;
select plan(9);

set local role student;
set request.jwt.claims = '{"role":"student","user_id":1,"iss":"yelukerest","aud":"yelukerest-postgrest","sub":"user:1"}';
SELECT lives_ok(
    'select api.check_request_jwt()',
    'api.check_request_jwt accepts expected issuer, audience, and subject'
);

reset request.jwt.claims;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
set request.jwt.claim.iss = 'yelukerest';
set request.jwt.claim.aud = 'yelukerest-postgrest';
set request.jwt.claim.sub = 'user:1';
SELECT lives_ok(
    'select api.check_request_jwt()',
    'api.check_request_jwt accepts individual PostgREST claim settings'
);

reset request.jwt.claim.role;
reset request.jwt.claim.user_id;
reset request.jwt.claim.iss;
reset request.jwt.claim.aud;
reset request.jwt.claim.sub;
set request.jwt.claims = '{"role":"student","user_id":1,"iss":"other","aud":"yelukerest-postgrest","sub":"user:1"}';
SELECT throws_like(
    'select api.check_request_jwt()',
    '%invalid jwt issuer%',
    'api.check_request_jwt rejects an unexpected issuer'
);

set request.jwt.claims = '{"role":"student","user_id":1,"iss":"yelukerest","aud":"other","sub":"user:1"}';
SELECT throws_like(
    'select api.check_request_jwt()',
    '%invalid jwt audience%',
    'api.check_request_jwt rejects an unexpected audience'
);

set request.jwt.claims = '{"role":"student","user_id":1,"iss":"yelukerest","aud":["yelukerest-postgrest"],"sub":"user:1"}';
SELECT lives_ok(
    'select api.check_request_jwt()',
    'api.check_request_jwt accepts audience arrays'
);

set request.jwt.claims = '{"role":"student","user_id":1,"iss":"yelukerest","aud":"yelukerest-postgrest","sub":"user:2"}';
SELECT throws_like(
    'select api.check_request_jwt()',
    '%invalid jwt subject%',
    'api.check_request_jwt rejects user subject mismatches'
);

set local role app;
set request.jwt.claims = '{"role":"app","app_name":"authapp","iss":"yelukerest","aud":"yelukerest-postgrest","sub":"app:authapp"}';
SELECT lives_ok(
    'select api.check_request_jwt()',
    'api.check_request_jwt accepts app subject matches'
);

set request.jwt.claims = '{"role":"app","app_name":"authapp","iss":"yelukerest","aud":"yelukerest-postgrest","sub":"app:other"}';
SELECT throws_like(
    'select api.check_request_jwt()',
    '%invalid jwt subject%',
    'api.check_request_jwt rejects app subject mismatches'
);

set request.jwt.claims = '{"role":"anonymous"}';
SELECT lives_ok(
    'select api.check_request_jwt()',
    'api.check_request_jwt does not require jwt claims for anonymous requests'
);

select * from finish();
rollback;
