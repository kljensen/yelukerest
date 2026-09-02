-- A draft assignment is visible to students and still not submittable.
--
-- `is_draft` used to hide an assignment outright, which conflated "not
-- finished" with "secret" and left the client's NotSubmissible IsDraft state
-- unreachable. Drafts are now visible and labelled, like draft meetings. That
-- is only safe while the refusal to accept a submission holds independently of
-- visibility, which is what this file pins.

select plan(7);

-- A draft and a published assignment, both with a field, to tell apart.

INSERT INTO data.assignment (slug, points_possible, is_draft, is_team, title, body, closed_at)
VALUES ('zz-draft-visible', 10, TRUE,  FALSE, 'Draft one', 'b', current_timestamp + interval '30 days'),
       ('zz-open-visible',  10, FALSE, FALSE, 'Open one',  'b', current_timestamp + interval '30 days');

INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder, is_url, is_multiline)
VALUES ('url', 'zz-draft-visible', 'l', 'h', 'p', FALSE, FALSE),
       ('url', 'zz-open-visible',  'l', 'h', 'p', FALSE, FALSE);

-- Become a student: role AND user id, which is what an API request carries.
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';

select is(
    (SELECT count(*)::int FROM api.assignments WHERE slug = 'zz-draft-visible'),
    1,
    'a student can see a draft assignment at all -- this is the change'
);

select is(
    (SELECT is_open FROM api.assignments WHERE slug = 'zz-draft-visible'),
    FALSE,
    'and it reports itself closed, so the client shows it as not submittable'
);

select is(
    (SELECT is_draft FROM api.assignments WHERE slug = 'zz-draft-visible'),
    TRUE,
    'the draft flag reaches the client, which is what it labels'
);

select is(
    (SELECT count(*)::int FROM api.assignment_fields WHERE assignment_slug = 'zz-draft-visible'),
    1,
    'its fields come too, or the page would render empty'
);

select is(
    (SELECT is_open FROM api.assignments WHERE slug = 'zz-open-visible'),
    TRUE,
    'a published assignment is still open, so nothing was broken in passing'
);

-- The guarantee that makes the visibility safe. Row-level security, not the
-- view and not the client, is what refuses this.
select throws_like(
    $$
        INSERT INTO api.assignment_submissions (assignment_slug, user_id, submitter_user_id)
        VALUES ('zz-draft-visible', 4, 4)
    $$,
    '%row-level security%',
    'a student still cannot submit to a draft, however visible it is'
);

-- The case that was open before this migration: a parent submission already
-- exists on the draft, and the student holds a live grade exception. The
-- ordinary branch of the field-write guard excluded drafts; the exception
-- branch did not, so this used to be writable.
-- Back to the migrator to build the fixture: the role is still student from
-- the assertions above, and student has no rights on data.*.
reset role;

INSERT INTO data.assignment_submission (assignment_slug, is_team, user_id, submitter_user_id)
VALUES ('zz-draft-visible', FALSE, 4, 4);

INSERT INTO data.assignment_grade_exception (assignment_slug, user_id, closed_at)
VALUES ('zz-draft-visible', 4, current_timestamp + interval '30 days');

-- Stash the id now, while data.* is still readable. A student cannot see that
-- schema at all, so the assertion below cannot look it up for itself.
CREATE TEMP TABLE zz_target AS
SELECT id FROM data.assignment_submission WHERE assignment_slug = 'zz-draft-visible';
GRANT SELECT ON zz_target TO student;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '4';

-- The case that was open before this migration: a parent submission exists on
-- the draft and the student holds a live grade exception. The ordinary branch
-- of the field-write guard excluded drafts; the exception branch did not, so
-- this used to be writable.
select throws_like(
    $$
        INSERT INTO api.assignment_field_submissions
            (assignment_submission_id, assignment_field_slug, assignment_slug, body)
        SELECT id, 'url', 'zz-draft-visible', 'anything' FROM zz_target
    $$,
    '%row-level security%',
    'a live grade exception does not make a draft writable'
);

select * from finish();
