-- Verify add-field-submission-origin. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot. This file re-runs against every later
-- state of the schema, so it asserts what must stay true for `origin` to keep
-- meaning anything -- never row counts or which labels happen to be in use
-- today.

-- Both tables carry the column, NOT NULL, as text.
SELECT 1 / (
    SELECT (count(*) = 2)::int
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'data'
       AND c.relname IN ('assignment_field_submission', 'assignment_field_submission_event')
       AND a.attname = 'origin'
       AND NOT a.attisdropped
       AND a.attnotnull
       AND a.atttypid = 'text'::regtype
);

-- Neither column may acquire a column default. A default would let a write
-- with no request identity say nothing about provenance and still succeed,
-- which is precisely the ambiguity this column exists to remove: the writer
-- has to state it, or be refused. The vocabulary may grow; the absence of a
-- default may not.
SELECT 1 / (
    SELECT (count(*) = 0)::int
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'data'
       AND c.relname IN ('assignment_field_submission', 'assignment_field_submission_event')
       AND a.attname = 'origin'
       AND NOT a.attisdropped
       AND a.atthasdef
);

-- A CHECK named origin_is_known constrains the vocabulary on both tables.
-- Asserted by name rather than by counting CHECKs that mention `origin`, so a
-- later migration adding a further origin-involving constraint does not
-- falsify this. The list of permitted labels is deliberately not asserted
-- either: adding one is an ordinary reversible constraint replacement and this
-- taxonomy is expected to grow. What must not happen is the column becoming
-- free text.
SELECT 1 / (
    SELECT (count(*) = 2)::int
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'origin'
     WHERE n.nspname = 'data'
       AND c.relname IN ('assignment_field_submission', 'assignment_field_submission_event')
       AND con.conname = 'origin_is_known'
       AND con.contype = 'c'
       AND a.attnum = ANY (con.conkey)
);

-- What the trigger functions *do* -- derive origin on insert, copy OLD.origin
-- on update, and copy the submission row's origin into the history -- is
-- asserted behaviourally in tests/db/yeluke-field-submission-origin.sql, and
-- deliberately not asserted here. This file re-runs against every later schema,
-- so matching on function source text would fail a behaviour-preserving
-- refactor of a correct implementation: it would pin the shape of the code
-- rather than any property of the database. What belongs here is that the
-- functions are still attached as triggers, since a function nobody calls
-- enforces nothing whatever its body says.
SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_trigger
     WHERE tgrelid = 'data.assignment_field_submission'::regclass
       AND NOT tgisinternal
       AND tgfoid = 'data.fill_assignment_field_submission_defaults()'::regprocedure
       AND (tgtype & 2) <> 0   -- BEFORE, so it runs ahead of the RLS WITH CHECK
       AND (tgtype & 1) <> 0   -- FOR EACH ROW
);

SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_trigger
     WHERE tgrelid = 'data.assignment_field_submission'::regclass
       AND NOT tgisinternal
       AND tgfoid = 'data.record_assignment_field_submission_event()'::regprocedure
);

-- The api views expose the column. `select *` expands once at creation time,
-- so a view that was not recreated still serves the old column list and every
-- reader -- PostgREST, mcpapp, the admin CLI -- stays blind to provenance
-- while the base table records it.
SELECT 1 / (
    SELECT (count(*) = 2)::int
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'api'
       AND c.relname IN ('assignment_field_submissions', 'assignment_field_submission_events')
       AND a.attname = 'origin'
       AND NOT a.attisdropped
);

-- Recreating a view is the easy way to lose its owner, and the view being
-- owned by `api` is what makes row-level security apply to it at all.
SELECT 1 / (
    SELECT (count(*) = 2)::int
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_roles r ON r.oid = c.relowner
     WHERE n.nspname = 'api'
       AND c.relname IN ('assignment_field_submissions', 'assignment_field_submission_events')
       AND r.rolname = 'api'
);
