-- Verify add-authapp-session-store. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema. Two things have to keep being true. The table has to keep the
-- exact shape scs/postgresstore's SQL expects, because a rename here fails at
-- runtime rather than at deploy time. And the session tokens have to stay
-- unreadable by anything except authapp, because the token column is the
-- bearer credential -- reading it is impersonating its owner.
--
-- The privilege assertions below compare against the exact intended set rather
-- than checking that the needed privileges are present. Presence checks pass
-- under drift: GRANT CREATE ON SCHEMA data TO authapp, or a stray TRUNCATE,
-- leaves every "can it still do its job" test green while the least-privilege
-- claim in deploy.sql quietly stops being true.

-- The role authapp logs in as, with the complete attribute set
-- authapp/sql/create-authapp-db-role.sh gives it. Provisioned outside the
-- migration graph, so this is the only place the graph can notice it has gone
-- missing -- which it would, silently, on a cluster rebuilt without that step.
--
-- Every attribute is pinned, not just the dangerous-sounding ones.
-- rolreplication would let it stream the whole cluster, including this table,
-- past every grant below. NOINHERIT is what makes the "no role memberships"
-- check next door meaningful the other way round: even a membership added by
-- hand confers nothing until it is explicitly assumed.
SELECT 1 / (
    SELECT (count(*) = 1)::int
      FROM pg_roles
     WHERE rolname = 'authapp'
       AND rolcanlogin
       AND NOT rolsuper
       AND NOT rolinherit
       AND NOT rolcreaterole
       AND NOT rolcreatedb
       AND NOT rolreplication
       AND NOT rolbypassrls
);

-- ...nor membership in an application role, which would let the session store
-- credential act as a person.
SELECT 1 / (
    SELECT (count(*) = 0)::int
      FROM pg_auth_members m
      JOIN pg_roles member ON member.oid = m.member
     WHERE member.rolname = 'authapp'
);

-- The table shape, column by column. token/data/expiry and their types are
-- scs/postgresstore's literal SQL.
SELECT 1 / (
    SELECT (count(*) = 3)::int
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'data'
       AND c.relname = 'authapp_session'
       AND c.relkind = 'r'
       AND a.attnum > 0
       AND NOT a.attisdropped
       AND (a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull) IN (
           ('token',  'text',                      true),
           ('data',   'bytea',                     true),
           ('expiry', 'timestamp with time zone',  true)
       )
);

-- ...and no fourth column, which would be a column SCS never writes and so
-- would have to be nullable or defaulted to be harmless.
SELECT 1 / (
    SELECT (count(*) = 3)::int
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'data'
       AND c.relname = 'authapp_session'
       AND a.attnum > 0
       AND NOT a.attisdropped
);

-- token is the primary key: Commit() upserts with ON CONFLICT (token).
SELECT 1 / (
    SELECT (count(*) = 1)::int
      FROM pg_index i
     WHERE i.indrelid = 'data.authapp_session'::regclass
       AND i.indisprimary
       AND i.indkey::text = (
           SELECT a.attnum::text FROM pg_attribute a
            WHERE a.attrelid = 'data.authapp_session'::regclass AND a.attname = 'token'
       )
);

-- An index led by expiry, so the cleanup delete does not scan the table.
SELECT 1 / (
    SELECT (count(*) > 0)::int
      FROM pg_index i
     WHERE i.indrelid = 'data.authapp_session'::regclass
       AND i.indisvalid
       AND i.indpred IS NULL
       AND (string_to_array(i.indkey::text, ' '))[1] = (
           SELECT a.attnum::text FROM pg_attribute a
            WHERE a.attrelid = 'data.authapp_session'::regclass AND a.attname = 'expiry'
       )
);

-- authapp can do what the store needs. Effective privilege, so this stays true
-- however the grant is routed; authapp's startup check runs the same four
-- statements for real before it will listen.
SELECT 1 / (
    (has_table_privilege('authapp', 'data.authapp_session', 'SELECT')
     AND has_table_privilege('authapp', 'data.authapp_session', 'INSERT')
     AND has_table_privilege('authapp', 'data.authapp_session', 'UPDATE')
     AND has_table_privilege('authapp', 'data.authapp_session', 'DELETE')
     AND has_schema_privilege('authapp', 'data', 'USAGE'))::int
);

-- ...and no more than that. The privilege names come from aclexplode rather
-- than a list written out here, so this keeps rejecting privileges PostgreSQL
-- has not invented yet -- MAINTAIN arrived in 17 and would have slipped past a
-- hand-written list of the seven that existed before it. No grant option
-- either: authapp handing SELECT to someone else is the failure this whole
-- section exists to prevent.
SELECT 1 / (
    SELECT coalesce(
        array_agg(a.privilege_type ORDER BY a.privilege_type) = ARRAY['DELETE', 'INSERT', 'SELECT', 'UPDATE']
        AND bool_and(NOT a.is_grantable),
    false)::int
      FROM pg_class c
      CROSS JOIN LATERAL aclexplode(c.relacl) a
      JOIN pg_roles g ON g.oid = a.grantee
     WHERE c.oid = 'data.authapp_session'::regclass
       AND g.rolname = 'authapp'
);

-- Nothing else may read a session token, whoever it is. Naming the grantees
-- rather than listing the roles that must be absent is what makes this hold
-- against a role invented later; grantee 0 is PUBLIC, which appears here as a
-- NULL rolname and so fails the comparison too.
SELECT 1 / (
    SELECT coalesce(
        array_agg(DISTINCT g.rolname::text) = ARRAY['authapp', 'yelukerest_migrator'],
    false)::int
      FROM pg_class c
      CROSS JOIN LATERAL aclexplode(c.relacl) a
      LEFT JOIN pg_roles g ON g.oid = a.grantee
     WHERE c.oid = 'data.authapp_session'::regclass
);

-- The same claim as effective privilege, which is the only way to see access
-- that arrives through role membership -- GRANT authapp TO student leaves the
-- table's own ACL untouched. Superusers are excluded because nothing here can
-- fence them, and the pg_ predefined roles because pg_read_all_data reaching
-- every table is PostgreSQL's design; a course role made a member of one of
-- them would still show up, under its own name.
SELECT 1 / (
    SELECT (count(*) = 0)::int
      FROM pg_roles r
     WHERE r.rolname NOT IN ('authapp', 'yelukerest_migrator')
       AND NOT r.rolsuper
       AND r.rolname NOT LIKE 'pg\_%'
       AND (has_table_privilege(r.oid, 'data.authapp_session', 'SELECT')
            OR has_table_privilege(r.oid, 'data.authapp_session', 'INSERT')
            OR has_table_privilege(r.oid, 'data.authapp_session', 'UPDATE')
            OR has_table_privilege(r.oid, 'data.authapp_session', 'DELETE'))
);

-- Column privileges live in pg_attribute, not in relacl, so GRANT SELECT
-- (token) ON data.authapp_session TO student would be invisible to every check
-- above. The migration grants none, so any at all is drift.
SELECT 1 / (
    SELECT (count(*) = 0)::int
      FROM pg_attribute a
     WHERE a.attrelid = 'data.authapp_session'::regclass
       AND a.attacl IS NOT NULL
);

-- USAGE on data and nothing else, anywhere. CREATE on schema data is the drift
-- worth naming: it lets authapp make its own tables in the schema that holds
-- the course data, and a "does it still have USAGE" check would never see it.
SELECT 1 / (
    SELECT (count(*) = 0)::int
      FROM pg_namespace n
      CROSS JOIN LATERAL aclexplode(n.nspacl) a
      JOIN pg_roles g ON g.oid = a.grantee
     WHERE g.rolname = 'authapp'
       AND NOT (n.nspname = 'data' AND a.privilege_type = 'USAGE')
);

-- The same claim as effective privilege, which catches the other route in:
-- GRANT CREATE ON SCHEMA data TO PUBLIC names no role, so it leaves nspacl
-- with no authapp row at all while still giving authapp CREATE.
SELECT 1 / ((NOT has_schema_privilege('authapp', 'data', 'CREATE'))::int);

-- The converse of everything above: authapp holds privileges on
-- data.authapp_session and on no other object in this database. It is a
-- session store credential, not a second way into the course data.
--
-- One object class per branch because PostgreSQL keeps each ACL in its own
-- catalog column, so there is no single place to look. Default ACLs are in
-- here because they are a grant on objects that do not exist yet: one
-- ALTER DEFAULT PRIVILEGES would hand authapp every table a later migration
-- creates, and nothing else in this file would notice.
SELECT 1 / (
    SELECT (count(*) = 0)::int FROM (
        SELECT 1
          FROM pg_class c
          CROSS JOIN LATERAL aclexplode(c.relacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE g.rolname = 'authapp'
           AND c.oid <> 'data.authapp_session'::regclass
        UNION ALL
        SELECT 1
          FROM pg_attribute at
          CROSS JOIN LATERAL aclexplode(at.attacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE g.rolname = 'authapp'
        UNION ALL
        SELECT 1
          FROM pg_proc p
          CROSS JOIN LATERAL aclexplode(p.proacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE g.rolname = 'authapp'
        UNION ALL
        SELECT 1
          FROM pg_type t
          CROSS JOIN LATERAL aclexplode(t.typacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE g.rolname = 'authapp'
        UNION ALL
        SELECT 1
          FROM pg_language l
          CROSS JOIN LATERAL aclexplode(l.lanacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE g.rolname = 'authapp'
        UNION ALL
        SELECT 1
          FROM pg_default_acl d
          CROSS JOIN LATERAL aclexplode(d.defaclacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE g.rolname = 'authapp'
        UNION ALL
        -- Only this database: pg_database is a shared catalog, and what some
        -- other database in the cluster grants is not this migration's claim
        -- to make. CONNECT reaches authapp through PUBLIC, so a row here means
        -- somebody granted it something by name.
        SELECT 1
          FROM pg_database db
          CROSS JOIN LATERAL aclexplode(db.datacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE g.rolname = 'authapp'
           AND db.datname = current_database()
    ) AS held_elsewhere
);

-- No api view may be built over the session table: PostgREST serves the api
-- schema, so a view there is a public read of the token column.
SELECT 1 / (
    SELECT (count(*) = 0)::int
      FROM pg_depend d
      JOIN pg_rewrite w ON w.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
      JOIN pg_class v ON v.oid = w.ev_class
      JOIN pg_namespace n ON n.oid = v.relnamespace
     WHERE d.refclassid = 'pg_class'::regclass
       AND d.refobjid = 'data.authapp_session'::regclass
       AND n.nspname = 'api'
);
