
select plan(5);


INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,pattern,example)
VALUES ('exam-1', 'pattern-field', 'gobblygook', 'find this online', 'e.g. foo', 'foo.*', 'foobar');

INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,pattern,example)
VALUES ('exam-1', 'pattern-field-no-anchor', 'gobblygook', 'find this online', 'e.g. foo', '.*foo.*', 'foobar');

INSERT INTO api.assignment_fields (assignment_slug,slug,label,help,placeholder,is_url,example)
VALUES ('exam-1', 'url-field', 'gobblygook', 'find this online', 'e.g. http://kljensen', true, 'https://foo.com');


-- Every write below states its `origin` because none of them carries a
-- request user id: the role claim alone is not an identity, and since #370
-- a write with no identity has to say how the row came to exist. 'staff'
-- because these stand in for a faculty session.
--
-- Changing to faculty role because I don't want to test RLS and such.
-- I am just testing constraints. So, I don't want to worry if the assignment
-- is open, etc.
set local role faculty;
set request.jwt.claim.role = 'faculty';

INSERT INTO api.assignment_submissions (id,assignment_slug, user_id, submitter_user_id) VALUES (6001,'exam-1', 4, 4);
SELECT throws_like(
    $$
      INSERT INTO
        api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,assignment_slug,body,origin)
      VALUES (6001, 'pattern-field', 'exam-1', 'xfoobarx', 'staff')
    $$,
    '%violates check constraint%',
  'assignment_field_submissions must match the assignment_field pattern (negative case)'
);

SELECT lives_ok(
    $$
      INSERT INTO
        api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,assignment_slug,body,origin)
      VALUES (6001, 'pattern-field-no-anchor', 'exam-1', 'xfoobarx', 'staff')
    $$,
  'assignment_field_submissions must match the assignment_field pattern (positive case)'
);

SELECT lives_ok(
    $$
      INSERT INTO
        api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,assignment_slug,body,origin)
      VALUES (6001, 'pattern-field', 'exam-1', 'foobarx', 'staff')
    $$,
  'assignment_field_submissions must match the assignment_field pattern (positive case)'
);

SELECT throws_like(
    $$
      INSERT INTO
        api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,assignment_slug,body,origin)
      VALUES (6001, 'url-field', 'exam-1', 'xfoobarx', 'staff')
    $$,
    '%violates check constraint%',
  'assignment_field_submissions require a body that is a URL if is_url is TRUE (negative case)'
);

SELECT lives_ok(
    $$
      INSERT INTO
        api.assignment_field_submissions (assignment_submission_id,assignment_field_slug,assignment_slug,body,origin)
      VALUES (6001, 'url-field', 'exam-1', 'https://xfoobarx', 'staff')
    $$,
  'assignment_field_submissions require a body that is a URL if is_url is TRUE (positive case)'
);

select * from finish();
