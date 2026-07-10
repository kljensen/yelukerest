begin;
select plan(5);

set local role student;
set request.jwt.claims = '{"role":"student","user_id":1,"iss":"yelukerest","aud":"yelukerest-postgrest","sub":"user:1"}';
SELECT lives_ok(
    'select api.check_request_jwt()',
    'api.check_request_jwt accepts expected issuer, audience, and subject'
);

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

set request.jwt.claims = '{"role":"anonymous"}';
SELECT lives_ok(
    'select api.check_request_jwt()',
    'api.check_request_jwt does not require jwt claims for anonymous requests'
);

select * from finish();
rollback;
