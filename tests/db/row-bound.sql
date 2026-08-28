-- The statement row bound on student and TA writes (issue #346).
--
-- The control this replaces was a PostgREST request preference sent by one
-- client (`Prefer: handling=strict, max-affected=1`, issue #337). A preference
-- binds only the client that chooses to send it, and it is verb-shaped, so it
-- missed the shape student writes actually take: a batch upsert POST, which
-- PostgREST turns into INSERT ... ON CONFLICT DO UPDATE. These tests are
-- against the database bound that replaced it, exercised through the api views
-- a student really writes through rather than against the base tables.

select * from no_plan();

-- Start from no request identity at all: a leaked claim from an earlier file
-- would make this file's fixture setup look like a student write.
SELECT set_config('request.jwt.claim.role', '', false);
SELECT set_config('request.jwt.claim.user_id', '', false);
SELECT set_config('request.jwt.claims', '', false);

-- ---------------------------------------------------------------- fixtures --
-- An open individual assignment with more fields than the bound, so a single
-- statement can be built either side of it.
INSERT INTO data.assignment (slug, points_possible, is_draft, is_team, title, body, closed_at)
VALUES ('zz-bound', 10, false, false, 'row bound fixture', '', current_timestamp + '30 days'::interval);

INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder)
SELECT 'f-' || g, 'zz-bound', 'label', 'help', 'placeholder'
FROM generate_series(1, 130) g;

INSERT INTO data.assignment_submission (assignment_slug, user_id, is_team, submitter_user_id)
VALUES ('zz-bound', 1, false, 1);

-- A second assignment and submission, so a statement can be made to span two
-- parent submissions.
INSERT INTO data.assignment (slug, points_possible, is_draft, is_team, title, body, closed_at)
VALUES ('zz-bound-b', 10, false, false, 'row bound fixture b', '', current_timestamp + '30 days'::interval);
INSERT INTO data.assignment_field (slug, assignment_slug, label, help, placeholder)
SELECT 'f-' || g, 'zz-bound-b', 'label', 'help', 'placeholder'
FROM generate_series(1, 5) g;
INSERT INTO data.assignment_submission (assignment_slug, user_id, is_team, submitter_user_id)
VALUES ('zz-bound-b', 1, false, 1);

-- Nine open individual assignments with no submission yet, for the stricter
-- bound on the parent table.
INSERT INTO data.assignment (slug, points_possible, is_draft, is_team, title, body, closed_at)
SELECT 'zz-sub-' || g, 10, false, false, 'parent bound fixture ' || g, '',
       current_timestamp + '30 days'::interval
FROM generate_series(1, 9) g;

-- Enough students that one meeting's engagement roster is larger than the
-- bound, which is what a TA marking attendance in one statement looks like.
INSERT INTO data."user" (email, netid, nickname, role)
SELECT 'zzu' || g || '@yale.edu', 'zzu' || g, 'zz-user' || g, 'student'
FROM generate_series(1, 70) g;

-- ------------------------------------------------------- the boundary -------
set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        INSERT INTO api.assignment_field_submissions (assignment_slug, assignment_field_slug, body)
        SELECT 'zz-bound', 'f-' || g, 'answer' FROM generate_series(1, 64) g
    $$,
    'a student may write exactly 64 rows in one statement'
);

SELECT throws_ok(
    $$
        INSERT INTO api.assignment_field_submissions (assignment_slug, assignment_field_slug, body)
        VALUES ('zz-bound', 'f-65', 'answer')
    $$,
    'PT400',
    NULL,
    'one row past the bound, in the same request, is refused'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_field_submissions WHERE assignment_slug = 'zz-bound'),
    64,
    'the refused statement changed nothing: still 64 rows'
);

-- A fresh request may write again: the bound is on breadth, not on total work.
SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        INSERT INTO api.assignment_field_submissions (assignment_slug, assignment_field_slug, body)
        VALUES ('zz-bound', 'f-65', 'answer')
    $$,
    'the next request starts from a fresh budget'
);

SELECT throws_ok(
    $$
        UPDATE api.assignment_field_submissions SET body = 'rewritten'
        WHERE assignment_slug = 'zz-bound'
    $$,
    'PT400',
    NULL,
    'an unfiltered UPDATE over 65 rows is refused'
);

-- ------------------------------------------- the upsert both-arms problem ---
-- PostgREST turns a POST carrying `Prefer: resolution=merge-duplicates` into
-- INSERT ... ON CONFLICT DO UPDATE, which fires the statement-level UPDATE
-- trigger and the statement-level INSERT trigger for the same statement. If
-- each firing were checked against the bound on its own, this statement --
-- 65 rows updated and 60 inserted, neither arm over 64 -- would be allowed,
-- and the effective bound would be twice what it says.
SELECT request.reset_row_bound_counters();

SELECT throws_ok(
    $$
        INSERT INTO api.assignment_field_submissions (assignment_slug, assignment_field_slug, body)
        SELECT 'zz-bound', 'f-' || g, 'upserted' FROM generate_series(1, 125) g
        ON CONFLICT (assignment_submission_id, assignment_field_slug)
        DO UPDATE SET body = excluded.body
    $$,
    'PT400',
    NULL,
    'a batch upsert is counted across both of its arms, not once per arm'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_field_submissions
      WHERE assignment_slug = 'zz-bound' AND body = 'upserted'),
    0,
    'the refused upsert wrote nothing'
);

-- The same shape at the bound is allowed: 60 updated plus 4 inserted is 64.
SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        INSERT INTO api.assignment_field_submissions (assignment_slug, assignment_field_slug, body)
        SELECT 'zz-bound', 'f-' || g, 'upserted' FROM generate_series(1, 60) g
        ON CONFLICT (assignment_submission_id, assignment_field_slug)
        DO UPDATE SET body = excluded.body
    $$,
    'an upsert whose two arms sum to the bound is allowed'
);

-- ------------------------------------------------- the Elm client's save ----
-- elmclient/src/elm/Assignments/Commands.elm posts one object per field of one
-- assignment with `Prefer: resolution=merge-duplicates`, and omits
-- assignment_submission_id: a BEFORE row trigger fills it. The bound must not
-- get in the way of that.
SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        INSERT INTO api.assignment_field_submissions (assignment_slug, assignment_field_slug, body)
        VALUES ('zz-bound-b', 'f-1', 'first'),
               ('zz-bound-b', 'f-2', 'second'),
               ('zz-bound-b', 'f-3', 'third'),
               ('zz-bound-b', 'f-4', 'fourth'),
               ('zz-bound-b', 'f-5', 'fifth')
        ON CONFLICT (assignment_submission_id, assignment_field_slug)
        DO UPDATE SET body = excluded.body
    $$,
    'the Elm client multi-field save still works'
);

-- ------------------------------------- one submission per statement ---------
SELECT request.reset_row_bound_counters();

SELECT throws_ok(
    $$
        UPDATE api.assignment_field_submissions SET body = 'across-two-submissions'
        WHERE assignment_slug IN ('zz-bound', 'zz-bound-b')
          AND assignment_field_slug IN ('f-1', 'f-2')
    $$,
    'PT400',
    NULL,
    'one statement may not span two assignment submissions'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_field_submissions
      WHERE body = 'across-two-submissions'),
    0,
    'the statement spanning two submissions changed nothing'
);

SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        UPDATE api.assignment_field_submissions SET body = 'within-one-submission'
        WHERE assignment_slug = 'zz-bound-b'
    $$,
    'a statement inside one submission is allowed'
);

-- ----------------------------------- the stricter bound on the parent -------
SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        INSERT INTO api.assignment_submissions (assignment_slug)
        SELECT 'zz-sub-' || g FROM generate_series(1, 4) g
    $$,
    'a student may create four assignment submissions in one statement'
);

SELECT throws_ok(
    $$INSERT INTO api.assignment_submissions (assignment_slug) VALUES ('zz-sub-5')$$,
    'PT400',
    NULL,
    'a fifth assignment submission in the same request is refused'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_submissions WHERE assignment_slug LIKE 'zz-sub-%'),
    4,
    'the refused parent insert changed nothing'
);

-- The bound is on the request, not on each statement: three then two is five.
SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        INSERT INTO api.assignment_submissions (assignment_slug)
        SELECT 'zz-sub-' || g FROM generate_series(5, 7) g
    $$,
    'three more submissions in a fresh request are allowed'
);

SELECT throws_ok(
    $$
        INSERT INTO api.assignment_submissions (assignment_slug)
        SELECT 'zz-sub-' || g FROM generate_series(8, 9) g
    $$,
    'PT400',
    NULL,
    'the parent bound counts the whole request, not each statement'
);

-- ------------------------------- claims delivered as JSON, as PostgREST does
-- The database test suite sets request.jwt.claim.* directly; real traffic
-- arrives with the whole claim set in request.jwt.claims (issue #345). Both
-- have to reach the trigger, or the bound passes its tests and does not bind
-- production.
RESET ROLE;
SELECT set_config('request.jwt.claim.role', '', false);
SELECT set_config('request.jwt.claim.user_id', '', false);
SELECT set_config('request.jwt.claims',
    json_build_object('role', 'student', 'user_id', 1, 'netid', 'abc123')::text,
    false);
SET LOCAL ROLE student;
SELECT request.reset_row_bound_counters();

SELECT throws_ok(
    $$
        UPDATE api.assignment_field_submissions SET body = 'json-claims'
        WHERE assignment_slug = 'zz-bound'
    $$,
    'PT400',
    NULL,
    'the bound reads the JSON claims GUC as well as the individual claim GUCs'
);

-- ------------------------------------- SECURITY DEFINER is not a way out ----
-- A SECURITY DEFINER function runs as its owner but does not erase the request
-- claims, so a multi-statement function still spends one budget rather than
-- getting a fresh one per statement.
RESET ROLE;
SELECT set_config('request.jwt.claims', '', false);

CREATE FUNCTION api.zz_two_statement_write() RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = pg_catalog, data, pg_temp
    AS $$
BEGIN
    UPDATE data.assignment_field_submission SET body = 'rpc-first'
     WHERE assignment_slug = 'zz-bound' AND assignment_field_slug IN (
         SELECT 'f-' || g FROM generate_series(1, 40) g);
    UPDATE data.assignment_field_submission SET body = 'rpc-second'
     WHERE assignment_slug = 'zz-bound' AND assignment_field_slug IN (
         SELECT 'f-' || g FROM generate_series(41, 65) g);
END;
$$;
GRANT EXECUTE ON FUNCTION api.zz_two_statement_write() TO student;

set local role student;
set request.jwt.claim.role = 'student';
set request.jwt.claim.user_id = '1';
SELECT request.reset_row_bound_counters();

SELECT throws_ok(
    $$SELECT api.zz_two_statement_write()$$,
    'PT400',
    NULL,
    'a multi-statement SECURITY DEFINER function does not reset the budget'
);

SELECT is(
    (SELECT count(*)::int FROM api.assignment_field_submissions WHERE body = 'rpc-first'),
    0,
    'the refused function call rolled back its earlier statement too'
);

-- ------------------------------------------------------------- the TA -------
RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'ta', false);
SELECT set_config('request.jwt.claim.user_id', '4', false);
set local role ta;
SELECT request.reset_row_bound_counters();

SELECT throws_ok(
    $$UPDATE api.engagements SET participation = 'led' WHERE meeting_slug = 'intro'$$,
    'PT400',
    NULL,
    'a TA marking a roster larger than the bound in one statement is refused'
);

SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        UPDATE api.engagements SET participation = 'attended'
        WHERE meeting_slug = 'intro'
          AND user_id IN (SELECT user_id FROM api.engagements
                           WHERE meeting_slug = 'intro' ORDER BY user_id LIMIT 64)
    $$,
    'a TA may mark 64 engagements in one statement'
);

-- --------------------------------------------------- faculty is exempt ------
RESET ROLE;
SELECT set_config('request.jwt.claim.role', 'faculty', false);
SELECT set_config('request.jwt.claim.user_id', '3', false);
set local role faculty;
SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        UPDATE api.assignment_field_submissions SET body = 'faculty-sweep'
        WHERE assignment_slug = 'zz-bound'
    $$,
    'faculty may rewrite every field submission of an assignment in one statement'
);

SELECT lives_ok(
    $$DELETE FROM api.engagements WHERE meeting_slug = 'intro'$$,
    'faculty bulk deletes -- what sync_meetings does -- are unaffected'
);

-- An admin or migration session with no request role at all is exempt too:
-- this is the path every import and every data load runs on.
RESET ROLE;
SELECT set_config('request.jwt.claim.role', '', false);
SELECT set_config('request.jwt.claim.user_id', '', false);
SELECT request.reset_row_bound_counters();

SELECT lives_ok(
    $$
        UPDATE data.assignment_field_submission SET body = 'admin-sweep'
        WHERE assignment_slug = 'zz-bound'
    $$,
    'a session with no request role is exempt'
);

select * from finish();
