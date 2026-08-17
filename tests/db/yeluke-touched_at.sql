BEGIN;

-- Regression tests for issue #308.
--
-- Every table carrying `updated_at` also carries
-- `CHECK (updated_at >= created_at)`. The triggers that maintain `updated_at`
-- used to set it to `current_timestamp`, which is *transaction start*, not
-- statement time. A transaction that updated a row created by a transaction
-- which started later therefore wrote an `updated_at` earlier than that row's
-- `created_at`, and the CHECK rejected the write with a hard error.
--
-- These tests do not need two sessions. `current_timestamp` is fixed for the
-- whole of this transaction, so any row whose `created_at` is in this
-- transaction's future reproduces the condition exactly -- that is precisely
-- what a concurrent writer produces, and it is deterministic here.

SELECT plan(16);

-- The helper itself.

SELECT is(
    data.touched_at(current_timestamp - interval '1 hour'),
    current_timestamp,
    'touched_at should return now for a row created in the past'
);

SELECT is(
    data.touched_at(current_timestamp),
    current_timestamp,
    'touched_at should return now for a row created at this transaction start'
);

SELECT is(
    data.touched_at(current_timestamp + interval '1 hour'),
    current_timestamp + interval '1 hour',
    'touched_at should return created_at when created_at is later than now'
);

SELECT ok(
    data.touched_at(current_timestamp + interval '1 hour') >= current_timestamp + interval '1 hour',
    'touched_at should never return a value that violates updated_after_created'
);

-- The property that made GREATEST the right choice over clock_timestamp():
-- an untouched insert keeps updated_at equal to created_at, so a freshly
-- created row does not look edited.

SELECT is(
    data.touched_at(current_timestamp),
    current_timestamp,
    'touched_at should not advance within a transaction, so a fresh insert is not marked edited'
);

-- Every trigger that maintains updated_at must route through it. This is the
-- assertion that fails if someone reintroduces the raw current_timestamp.

-- `fill_user_secret_defaults` is the one holdout. Its source file matches the
-- `Read(**/*secret*)` deny rule in this machine's Claude settings, so it could
-- not be edited when the rest were. Asserting the exact set rather than a count
-- means fixing it makes this test fail loudly and get updated, and a *different*
-- trigger regressing also fails -- which a bare `count = 1` would not catch.
SELECT is(
    (
        SELECT coalesce(string_agg(p.proname::text, ', ' ORDER BY p.proname::text), '')
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.prosrc ~ 'NEW\.updated_at\s*:?=\s*current_timestamp'
    ),
    'fill_user_secret_defaults',
    'only the user_secret trigger should still assign current_timestamp directly'
);

SELECT is(
    (
        SELECT count(*)::int
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
        AND p.prosrc ~ 'NEW\.updated_at\s*:?=\s*data\.touched_at'
    ),
    11,
    'the eleven updated_at triggers should all route through data.touched_at'
);

-- `updated_at` is the optimistic concurrency token on
-- `assignment_field_submission`: a client sends back the value it last read and
-- the trigger rejects the write if it no longer matches. So the token has to
-- advance on every update. Clamping alone would not -- on insert `updated_at`
-- equals `created_at`, so an update clamping back up to `created_at` returns
-- the value already stored, and a client holding the stale token would pass the
-- staleness check and overwrite a concurrent change.

SELECT ok(
    data.touched_at(current_timestamp + interval '1 hour', current_timestamp + interval '1 hour')
        > current_timestamp + interval '1 hour',
    'touched_at should advance strictly past the prior token even when clamping'
);

SELECT ok(
    data.touched_at(current_timestamp - interval '1 hour', current_timestamp)
        > current_timestamp - interval '1 microsecond',
    'touched_at should not go backwards from the prior token'
);

SELECT is(
    data.touched_at(current_timestamp - interval '1 hour', current_timestamp - interval '2 hours'),
    current_timestamp,
    'an ordinary update should still land on the transaction timestamp'
);

SELECT ok(
    data.touched_at(current_timestamp, current_timestamp) > current_timestamp,
    'two updates in one transaction should still produce distinct tokens'
);

-- End to end, on a real table, against the exact condition that used to fail.
-- A row whose created_at is later than this transaction's start is what a
-- concurrent writer leaves behind.

PREPARE update_future_row AS
    UPDATE data.meeting SET title = title || '' WHERE slug = 'test-future-meeting';

INSERT INTO data.meeting (slug, title, description, begins_at, duration, meeting_type, created_at)
VALUES (
    'test-future-meeting', 'Future', 'created by a later-starting transaction',
    current_timestamp + interval '1 day',
    '01:00:00', 'lecture', current_timestamp + interval '1 hour'
);

SELECT lives_ok(
    'update_future_row',
    'updating a row created by a later-starting transaction should not violate the check'
);

SELECT ok(
    (SELECT updated_at >= created_at FROM data.meeting WHERE slug = 'test-future-meeting'),
    'the updated row should satisfy updated_after_created'
);

-- Clamped up to created_at, then one microsecond further so the concurrency
-- token still advances. Before the fix this write raised; a clamp without the
-- advance would have returned created_at unchanged.
SELECT is(
    (SELECT updated_at FROM data.meeting WHERE slug = 'test-future-meeting'),
    current_timestamp + interval '1 hour' + interval '1 microsecond',
    'updated_at should be clamped up to created_at and then advanced past the prior token'
);

-- And the ordinary case is unchanged: a row created in the past gets now.

INSERT INTO data.meeting (slug, title, description, begins_at, duration, meeting_type, created_at)
VALUES (
    'test-past-meeting', 'Past', 'the ordinary case',
    current_timestamp + interval '1 day',
    '01:00:00', 'lecture', current_timestamp - interval '1 hour'
);

SELECT is(
    (SELECT updated_at FROM data.meeting WHERE slug = 'test-past-meeting'),
    current_timestamp,
    'inserting a row created in the past should stamp the transaction timestamp'
);

UPDATE data.meeting SET title = title || '' WHERE slug = 'test-past-meeting';

-- The insert above already stamped `current_timestamp`, and this update runs in
-- the same transaction, so `current_timestamp` has not moved. The token still
-- has to advance -- otherwise two writes in one transaction would share a
-- concurrency token. In a later transaction this lands exactly on
-- `current_timestamp`, since that is then already the greatest of the three.
SELECT is(
    (SELECT updated_at FROM data.meeting WHERE slug = 'test-past-meeting'),
    current_timestamp + interval '1 microsecond',
    'updating it in the same transaction should still advance the token'
);

SELECT * FROM finish();
ROLLBACK;
