-- Verify add-short-links. READ ONLY and always rolled back.
--
-- Invariants, not a snapshot. What must stay true is who can write links (staff,
-- and only slug and url), who can follow them (anonymous, through a pinned
-- security-definer resolver), and that the table is not forced into its own
-- policy, which would leave the resolver reading nothing. Behaviour -- what the
-- constraints refuse, what the resolver answers -- is asserted in
-- tests/db/yeluke-short-link.sql.
-- The table exists, owned by the migrator, with RLS enabled and not forced.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE
            n.nspname = 'data'
            AND c.relname = 'short_link'
            AND c.relkind = 'r'
            AND pg_get_userbyid(c.relowner) = 'yelukerest_migrator'
            AND c.relrowsecurity
            AND NOT c.relforcerowsecurity
    )
;
-- The slug and URL constraints, by name.
SELECT
    1 / (
        SELECT (count(*) = 5)::int
        FROM pg_constraint
        WHERE
            conrelid = 'data.short_link'::regclass
            AND contype = 'c'
            AND conname IN ('short_link_slug_shape', 'short_link_slug_not_reserved', 'short_link_url_https_with_host', 'short_link_url_max_bytes', 'short_link_url_no_space_control_or_backslash')
    )
;
-- The one policy: for api, every command, staff claims only, on both read
-- and write.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_policy p
        WHERE
            p.polrelid = 'data.short_link'::regclass
            AND p.polname = 'short_link_staff'
            AND p.polcmd = '*'
            AND p.polpermissive
            AND p.polroles = ARRAY['api'::regrole::oid]
            AND pg_get_expr(p.polqual, p.polrelid) = '(request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text]))'
            AND pg_get_expr(p.polwithcheck, p.polrelid) = '(request.user_role() = ANY (ARRAY[''faculty''::text, ''ta''::text]))'
    )
; SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_policy
        WHERE polrelid = 'data.short_link'::regclass
    )
;
-- Faculty and TAs hold what managing links needs: SELECT and DELETE on the
-- view, INSERT and UPDATE on slug and url.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            (
                VALUES ('faculty'), ('ta')
            ) r(rolname)
        WHERE
            NOT (has_table_privilege(r.rolname, 'api.short_links', 'SELECT')
            AND has_table_privilege(r.rolname, 'api.short_links', 'DELETE')
            AND has_column_privilege(r.rolname, 'api.short_links', 'slug', 'INSERT')
            AND has_column_privilege(r.rolname, 'api.short_links', 'url', 'INSERT')
            AND has_column_privilege(r.rolname, 'api.short_links', 'slug', 'UPDATE')
            AND has_column_privilege(r.rolname, 'api.short_links', 'url', 'UPDATE'))
    )
;
-- The view is owned by api, so the table's policy governs it.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM
            pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE
            n.nspname = 'api'
            AND c.relname = 'short_links'
            AND c.relkind = 'v'
            AND pg_get_userbyid(c.relowner) = 'api'
    )
;
-- No role but faculty and TAs can touch the view at all.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_roles r
        WHERE
            r.rolname IN ('anonymous', 'student', 'observer', 'app')
            AND (has_table_privilege(r.oid, 'api.short_links', 'SELECT, INSERT, UPDATE, DELETE') OR has_any_column_privilege(r.oid, 'api.short_links', 'SELECT, INSERT, UPDATE'))
    )
;
-- Staff write slug and url and nothing else: the audit columns cannot be
-- inserted or updated by any application role, through the view or directly.
-- The view owner, api, holds every privilege on its own view, so for api it is
-- the table grant that bounds a write.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM
            pg_roles r
            CROSS JOIN (
                VALUES ('api.short_links'), ('data.short_link')
            ) t(rel)
            CROSS JOIN (
                VALUES ('created_by_user_id'), ('created_at'), ('updated_at')
            ) c(col)
            CROSS JOIN (
                VALUES ('INSERT'), ('UPDATE')
            ) p(privilege)
        WHERE
            (r.rolname IN ('anonymous', 'student', 'observer', 'app', 'faculty', 'ta') OR (r.rolname = 'api'
            AND t.rel = 'data.short_link'))
            AND has_column_privilege(r.oid, t.rel, c.col, p.privilege)
    )
;
-- Nobody but the view owner reaches the table directly.
SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_roles r
        WHERE
            r.rolname IN ('anonymous', 'student', 'observer', 'app', 'faculty', 'ta')
            AND (has_table_privilege(r.oid, 'data.short_link', 'SELECT, INSERT, UPDATE, DELETE') OR has_any_column_privilege(r.oid, 'data.short_link', 'SELECT, INSERT, UPDATE'))
    )
;
-- The resolver: security definer, owned by the table owner, search_path
-- pinned, executable by anonymous and no other application role.
SELECT
    1 / (
        SELECT (count(*) = 1)::int
        FROM pg_proc p
        WHERE
            p.oid = 'api.follow_short_link(text)'::regprocedure
            AND p.prosecdef
            AND p.provolatile = 's'
            AND p.prorettype = 'void'::regtype
            AND pg_get_userbyid(p.proowner) = 'yelukerest_migrator'
            AND p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp']
    )
; SELECT 1 / has_function_privilege('anonymous', 'api.follow_short_link(text)', 'EXECUTE')::int
; SELECT 1 / (NOT has_function_privilege('public', 'api.follow_short_link(text)', 'EXECUTE'))::int
; SELECT
    1 / (
        SELECT (count(*) = 0)::int
        FROM pg_roles r
        WHERE
            r.rolname IN ('student', 'ta', 'faculty', 'observer', 'app')
            AND has_function_privilege(r.oid, 'api.follow_short_link(text)', 'EXECUTE')
    )
