-- Verify bound-student-row-writes. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema, so a migration that adds a table students may write, or
-- widens a grant, fails here until it also carries the bound.

-- The machinery exists.
SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'data' AND p.proname = 'enforce_request_row_bound'
);

SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'data' AND p.proname = 'request_row_bound_default'
);

SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'request' AND p.proname = 'reset_row_bound_counters'
);

-- The budget is started at the top of every PostgREST request, or the bound
-- would be per pooled connection rather than per request.
SELECT 1 / (
    SELECT (prosrc LIKE '%reset_row_bound_counters%')::int
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'api' AND p.proname = 'check_request_jwt'
);

-- The invariant that matters: every base table a student or TA may write
-- carries a statement-level bound trigger for INSERT, UPDATE and DELETE.
-- Writable means an INSERT, UPDATE or DELETE grant to `student` or `ta`,
-- either on the table or on an auto-updatable api view over it -- which is
-- necessarily a view over a single base table, so resolving the view through
-- pg_rewrite gives exactly the table the write lands on.
SELECT 1 / (
    SELECT (count(*) = 0)::int
    FROM (
        WITH granted AS (
            SELECT c.oid, c.relkind
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            CROSS JOIN LATERAL aclexplode(c.relacl) a
            JOIN pg_roles r ON r.oid = a.grantee
            WHERE r.rolname IN ('student', 'ta')
              AND a.privilege_type IN ('INSERT', 'UPDATE', 'DELETE')
              AND n.nspname IN ('api', 'data')
        ), base_tables AS (
            SELECT DISTINCT oid FROM granted WHERE relkind = 'r'
            UNION
            SELECT DISTINCT d.refobjid
            FROM granted g
            JOIN pg_rewrite w ON w.ev_class = g.oid
            JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass
                            AND d.objid = w.oid
                            AND d.refclassid = 'pg_class'::regclass
            JOIN pg_class t ON t.oid = d.refobjid AND t.relkind = 'r'
            WHERE g.relkind = 'v'
        )
        SELECT b.oid
        FROM base_tables b
        WHERE (
            SELECT count(DISTINCT tg.tgtype)
            FROM pg_trigger tg
            WHERE tg.tgrelid = b.oid
              AND NOT tg.tgisinternal
              AND tg.tgfoid = 'data.enforce_request_row_bound()'::regprocedure
        ) < 3
    ) AS unbounded
);

-- The Elm client's save writes one row per field of one submission, and that
-- is the unit one statement may touch. Asserted for INSERT, UPDATE and DELETE.
SELECT 1 / (
    SELECT (count(DISTINCT tg.tgtype) = 3)::int
    FROM pg_trigger tg
    WHERE tg.tgrelid = 'data.assignment_field_submission'::regclass
      AND NOT tg.tgisinternal
      AND tg.tgfoid = 'data.enforce_single_assignment_submission()'::regprocedure
);

-- Every bound trigger must be AFTER ... FOR EACH STATEMENT with a transition
-- table. A FOR EACH ROW trigger would see one row at a time and never learn
-- the breadth of the statement, so it would pass this file's existence checks
-- while enforcing nothing.
SELECT 1 / (
    SELECT (count(*) = 0)::int
    FROM pg_trigger tg
    WHERE NOT tg.tgisinternal
      AND tg.tgfoid IN (
          'data.enforce_request_row_bound()'::regprocedure,
          'data.enforce_single_assignment_submission()'::regprocedure
      )
      AND (
          (tg.tgtype & 1) <> 0                                    -- FOR EACH ROW
          OR (tg.tgtype & 2) <> 0                                 -- BEFORE
          OR (tg.tgoldtable IS NULL AND tg.tgnewtable IS NULL)     -- no transition table
      )
);
