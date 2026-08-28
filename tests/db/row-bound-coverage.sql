-- Coverage for the statement row bound (issue #346).
--
-- tests/db/row-bound.sql proves the bound behaves. This file proves it is
-- attached everywhere it has to be, so it does not rot the first time somebody
-- adds a table or widens a grant. The migration's verify.sql asserts the same
-- invariant against every later schema state; this is the copy that runs with
-- the rest of the suite.

select * from no_plan();

-- Which base tables a student or TA can write, resolved from the catalogs
-- rather than from a list somebody has to remember to update. An api view a
-- student may write through is auto-updatable, which means it is a view over a
-- single base table, so resolving it through pg_rewrite names exactly the
-- table the write lands on.
CREATE VIEW pg_temp.writable_base_table AS
WITH granted AS (
    SELECT c.oid, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(c.relacl) a
    JOIN pg_roles r ON r.oid = a.grantee
    WHERE r.rolname IN ('student', 'ta')
      AND a.privilege_type IN ('INSERT', 'UPDATE', 'DELETE')
      AND n.nspname IN ('api', 'data')
)
SELECT DISTINCT oid AS reloid FROM granted WHERE relkind = 'r'
UNION
SELECT DISTINCT d.refobjid
FROM granted g
JOIN pg_rewrite w ON w.ev_class = g.oid
JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass
                AND d.objid = w.oid
                AND d.refclassid = 'pg_class'::regclass
JOIN pg_class t ON t.oid = d.refobjid AND t.relkind = 'r'
WHERE g.relkind = 'v';

SELECT set_eq(
    $$
        SELECT n.nspname || '.' || c.relname
        FROM pg_temp.writable_base_table b
        JOIN pg_class c ON c.oid = b.reloid
        JOIN pg_namespace n ON n.oid = c.relnamespace
    $$,
    ARRAY[
        'data.assignment_field_submission',
        'data.assignment_submission',
        'data.engagement'
    ],
    'the set of base tables a student or TA may write is the one this bound was designed for'
);

-- The invariant that survives a new table: every writable base table carries
-- the bound for INSERT, UPDATE and DELETE. All three even where no grant
-- exists yet, so widening a grant later does not silently widen the bound.
SELECT is_empty(
    $$
        SELECT n.nspname || '.' || c.relname
        FROM pg_temp.writable_base_table b
        JOIN pg_class c ON c.oid = b.reloid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE (
            SELECT count(DISTINCT tg.tgtype)
            FROM pg_trigger tg
            WHERE tg.tgrelid = b.reloid
              AND NOT tg.tgisinternal
              AND tg.tgfoid = 'data.enforce_request_row_bound()'::regprocedure
        ) < 3
    $$,
    'every student or TA writable base table carries the row bound on insert, update and delete'
);

-- A FOR EACH ROW or BEFORE trigger would see one row at a time and never learn
-- the breadth of the statement: it would satisfy the check above and enforce
-- nothing.
SELECT is_empty(
    $$
        SELECT n.nspname || '.' || c.relname || '.' || tg.tgname
        FROM pg_trigger tg
        JOIN pg_class c ON c.oid = tg.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE NOT tg.tgisinternal
          AND tg.tgfoid IN (
              'data.enforce_request_row_bound()'::regprocedure,
              'data.enforce_single_assignment_submission()'::regprocedure
          )
          AND (
              (tg.tgtype & 1) <> 0
              OR (tg.tgtype & 2) <> 0
              OR (tg.tgoldtable IS NULL AND tg.tgnewtable IS NULL)
          )
    $$,
    'every row-bound trigger is AFTER, statement level, and has a transition table'
);

-- The Elm client's save is one submission's fields, and that is the unit one
-- statement may touch.
SELECT is(
    (SELECT count(DISTINCT tgtype)::int
       FROM pg_trigger
      WHERE tgrelid = 'data.assignment_field_submission'::regclass
        AND NOT tgisinternal
        AND tgfoid = 'data.enforce_single_assignment_submission()'::regprocedure),
    3,
    'assignment field submissions are held to one parent submission per statement'
);

-- The numbers, so a change to either is a deliberate edit to this file.
SELECT is(
    data.request_row_bound_default(),
    64,
    'the default bound is 64 rows per request'
);

SELECT is(
    (SELECT count(*)::int
       FROM pg_trigger
      WHERE tgrelid = 'data.assignment_submission'::regclass
        AND NOT tgisinternal
        AND tgfoid = 'data.enforce_request_row_bound()'::regprocedure
        AND pg_get_triggerdef(oid) LIKE '%enforce_request_row_bound(''4'')'),
    3,
    'assignment submissions keep the stricter bound of 4 rows per request'
);

-- The trigger runs as the acting role, and a student has no USAGE on schema
-- data, so the bound has to be SECURITY DEFINER with a pinned search_path.
SELECT set_eq(
    $$
        SELECT p.proname::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'data'
          AND p.proname IN ('enforce_request_row_bound', 'enforce_single_assignment_submission')
          AND p.prosecdef
          AND p.proconfig @> ARRAY['search_path=pg_catalog, data, request, pg_temp']
    $$,
    ARRAY['enforce_request_row_bound', 'enforce_single_assignment_submission'],
    'the row-bound trigger functions are security definers with a pinned search_path'
);

-- The budget is started at the top of every PostgREST request. Without this
-- the bound would be per pooled connection rather than per request.
SELECT is(
    (SELECT (prosrc LIKE '%reset_row_bound_counters%')
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'api' AND p.proname = 'check_request_jwt'),
    true,
    'api.check_request_jwt starts a fresh row budget for every request'
);

-- The reset lives in `request`, a schema PostgREST does not expose, so no
-- client can call it to clear its own budget.
SELECT is(
    (SELECT count(*)::int
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'request' AND p.proname = 'reset_row_bound_counters'),
    1,
    'the budget reset exists outside the schema PostgREST exposes'
);

select * from finish();
