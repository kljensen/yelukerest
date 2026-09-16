-- Verify add-api-grants. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema. What must stay true is that a grant's permissions cannot be
-- rewritten, that a referenced field cannot be renamed or dropped from under a
-- grant, and that nothing but faculty can read the listing. Behaviour -- what
-- the validation refuses, what a second revoke leaves alone -- is asserted in
-- tests/db/yeluke-api-grants.sql, where a failure names the case.
-- The three tables exist, owned by the migrator.
SELECT
    1 / (
        SELECT (count(*) = 3)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE
            n.nspname = 'data'
            AND c.relname IN ('api_grant', 'api_grant_assignment', 'api_grant_assignment_field')
            AND c.relkind = 'r'
            AND pg_get_userbyid(c.relowner) = 'yelukerest_migrator'
    )
;
-- The lifecycle constraints, by name: expiry after creation and within 180
-- days, revocation naming both actor and time or neither.
SELECT
    1 / (
        SELECT (count(*) = 4)::int
        FROM pg_constraint
        WHERE
            conrelid = 'data.api_grant'::regclass
            AND contype = 'c'
            AND conname IN ('api_grant_expires_after_creation', 'api_grant_max_lifetime', 'api_grant_revocation_names_actor_and_time', 'api_grant_revoked_after_creation')
    )
;
-- Every foreign key from the grant tables is restrictive: NO ACTION on both
-- update and delete. A cascade here would let a field rename or drop rewrite
-- or erase a grant's permissions.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_constraint
        WHERE
            conrelid IN ('data.api_grant'::regclass, 'data.api_grant_assignment'::regclass, 'data.api_grant_assignment_field'::regclass)
            AND contype = 'f'
            AND (confupdtype <> 'a' OR confdeltype <> 'a')
    )
;
-- ...and the field key targets the composite primary key of
-- data.assignment_field, so a grant names a field of one assignment.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_constraint
        WHERE
            conrelid = 'data.api_grant_assignment_field'::regclass
            AND contype = 'f'
            AND confrelid = 'data.assignment_field'::regclass
            AND cardinality(conkey) = 2
    )
;
-- Immutability is enforced by triggers that are still attached: one on each
-- permission table for every operation, and the update guard on the grant.
-- tgtype bits: 2 BEFORE, 4 INSERT, 8 DELETE, 16 UPDATE.
SELECT
    1 / (
        SELECT (count(*) = 2)::int
        FROM pg_trigger
        WHERE
            tgrelid IN ('data.api_grant_assignment'::regclass, 'data.api_grant_assignment_field'::regclass)
            AND NOT tgisinternal
            AND tgfoid = 'data.api_grant_permissions_are_immutable()'::regprocedure
            AND (tgtype & 2) <> 0
            AND (tgtype & 4) <> 0
            AND (tgtype & 8) <> 0
            AND (tgtype & 16) <> 0
    )
; SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_trigger
        WHERE
            tgrelid = 'data.api_grant'::regclass
            AND NOT tgisinternal
            AND tgfoid = 'data.api_grant_allows_only_first_revocation()'::regprocedure
            AND (tgtype & 2) <> 0
            AND (tgtype & 16) <> 0
    )
;
-- The validated insert exists and is not executable by PUBLIC; the revoke RPC
-- is SECURITY DEFINER, executable by faculty and by no other application role.
SELECT
    1 / (
        SELECT (NOT has_function_privilege('public', 'data.create_api_grant_rows(text, jsonb, timestamp with time zone, int)', 'EXECUTE'))::int
    )
; SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE
            n.nspname = 'api'
            AND p.proname = 'revoke_api_grant'
            AND p.prosecdef
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_roles r
        WHERE
            r.rolname IN ('anonymous', 'student', 'ta', 'observer', 'app')
            AND has_function_privilege(r.oid, 'api.revoke_api_grant(int)', 'EXECUTE')
    )
; SELECT 1 / has_function_privilege('faculty', 'api.revoke_api_grant(int)', 'EXECUTE')::int
;
-- The listing view is owned by api, so its reads go through api's table
-- privileges, and only faculty may select from it.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE
            n.nspname = 'api'
            AND c.relname = 'api_grants'
            AND c.relkind = 'v'
            AND pg_get_userbyid(c.relowner) = 'api'
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_roles r
        WHERE
            r.rolname IN ('anonymous', 'student', 'ta', 'observer', 'app')
            AND has_table_privilege(r.oid, 'api.api_grants', 'SELECT')
    )
; SELECT 1 / has_table_privilege('faculty', 'api.api_grants', 'SELECT')::int
;
-- No application role may write the grant tables through the view or
-- directly: creation and revocation go through the functions above. The view
-- owner, api, holds every privilege on the view as owner but only SELECT on
-- the tables beneath it, so a write through the view fails there.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_roles r
            CROSS JOIN (
                VALUES
                    ('api.api_grants'), ('data.api_grant'),
                    ('data.api_grant_assignment'),
                    ('data.api_grant_assignment_field')
            ) t(rel)
        WHERE
            r.rolname IN ('anonymous', 'student', 'ta', 'observer', 'app', 'faculty')
            AND (has_table_privilege(r.oid, t.rel, 'INSERT') OR has_table_privilege(r.oid, t.rel, 'UPDATE') OR has_table_privilege(r.oid, t.rel, 'DELETE'))
    )
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            (
                VALUES
                    ('data.api_grant'), ('data.api_grant_assignment'),
                    ('data.api_grant_assignment_field')
            ) t(rel)
        WHERE has_table_privilege('api', t.rel, 'INSERT') OR has_table_privilege('api', t.rel, 'UPDATE') OR has_table_privilege('api', t.rel, 'DELETE')
    )
