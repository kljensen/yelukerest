SELECT plan(9)
; SET LOCAL role TO student
; SET "request.jwt.claims" TO '{"role":"student","user_id":1,"iss":"yelukerest","aud":"yelukerest-postgrest","sub":"user:1"}'
; SELECT lives_ok('select api.check_request_jwt()', 'api.check_request_jwt accepts expected issuer, audience, and subject')
; RESET "request.jwt.claims"
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SET "request.jwt.claim.iss" TO yelukerest
; SET "request.jwt.claim.aud" TO "yelukerest-postgrest"
; SET "request.jwt.claim.sub" TO "user:1"
; SELECT lives_ok('select api.check_request_jwt()', 'api.check_request_jwt accepts individual PostgREST claim settings')
; RESET "request.jwt.claim.role"
; RESET "request.jwt.claim.user_id"
; RESET "request.jwt.claim.iss"
; RESET "request.jwt.claim.aud"
; RESET "request.jwt.claim.sub"
; SET "request.jwt.claims" TO '{"role":"student","user_id":1,"iss":"other","aud":"yelukerest-postgrest","sub":"user:1"}'
; SELECT throws_like('select api.check_request_jwt()', '%invalid jwt issuer%', 'api.check_request_jwt rejects an unexpected issuer')
; SET "request.jwt.claims" TO '{"role":"student","user_id":1,"iss":"yelukerest","aud":"other","sub":"user:1"}'
; SELECT throws_like('select api.check_request_jwt()', '%invalid jwt audience%', 'api.check_request_jwt rejects an unexpected audience')
; SET "request.jwt.claims" TO '{"role":"student","user_id":1,"iss":"yelukerest","aud":["yelukerest-postgrest"],"sub":"user:1"}'
; SELECT lives_ok('select api.check_request_jwt()', 'api.check_request_jwt accepts audience arrays')
; SET "request.jwt.claims" TO '{"role":"student","user_id":1,"iss":"yelukerest","aud":"yelukerest-postgrest","sub":"user:2"}'
; SELECT throws_like('select api.check_request_jwt()', '%invalid jwt subject%', 'api.check_request_jwt rejects user subject mismatches')
; SET LOCAL role TO app
; SET "request.jwt.claims" TO '{"role":"app","app_name":"authapp","iss":"yelukerest","aud":"yelukerest-postgrest","sub":"app:authapp"}'
; SELECT lives_ok('select api.check_request_jwt()', 'api.check_request_jwt accepts app subject matches')
; SET "request.jwt.claims" TO '{"role":"app","app_name":"authapp","iss":"yelukerest","aud":"yelukerest-postgrest","sub":"app:other"}'
; SELECT throws_like('select api.check_request_jwt()', '%invalid jwt subject%', 'api.check_request_jwt rejects app subject mismatches')
; SET "request.jwt.claims" TO "{""role"":""anonymous""}"
; SELECT lives_ok('select api.check_request_jwt()', 'api.check_request_jwt does not require jwt claims for anonymous requests')
; SELECT *
FROM finish()
