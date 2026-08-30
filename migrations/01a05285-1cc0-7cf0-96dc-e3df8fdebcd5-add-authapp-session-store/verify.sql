-- Verify add-authapp-session-store. READ ONLY and always rolled back.
--
-- These are invariants, not a snapshot: they re-run against every later state
-- of the schema. Two things have to keep being true. The table has to keep the
-- exact shape scs/postgresstore's SQL expects, because a rename here fails at
-- runtime rather than at deploy time. And the session tokens have to stay
-- unreadable by anything except authapp, because the token column is the
-- bearer credential -- reading it is impersonating its owner.

-- The role authapp logs in as. It is provisioned outside the migration graph
-- (authapp/sql/create-authapp-db-role.sh), so this is the only place the graph
-- can notice it has gone missing -- which it would, silently, on a cluster
-- rebuilt without that step.
SELECT 1 / (
    SELECT (count(*) = 1)::int FROM pg_roles WHERE rolname = 'authapp' AND rolcanlogin
);

-- It must never gain the attributes that would make the grants below
-- irrelevant.
SELECT 1 / (
    SELECT (count(*) = 1)::int
      FROM pg_roles
     WHERE rolname = 'authapp'
       AND NOT (rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb)
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

-- authapp can do exactly what the store needs, and can reach the schema.
SELECT 1 / (
    (has_table_privilege('authapp', 'data.authapp_session', 'SELECT')
     AND has_table_privilege('authapp', 'data.authapp_session', 'INSERT')
     AND has_table_privilege('authapp', 'data.authapp_session', 'UPDATE')
     AND has_table_privilege('authapp', 'data.authapp_session', 'DELETE')
     AND has_schema_privilege('authapp', 'data', 'USAGE'))::int
);

-- Nothing else may read a session token. Every role that reaches the database
-- through PostgREST is named here; a later migration that hands one of them a
-- privilege on this table fails right here, which is the point.
SELECT 1 / (
    SELECT (count(*) = 0)::int
      FROM unnest(ARRAY['anonymous', 'api', 'app', 'faculty', 'observer', 'student', 'ta']) AS r(rolname)
     WHERE EXISTS (SELECT FROM pg_roles WHERE pg_roles.rolname = r.rolname)
       AND (has_table_privilege(r.rolname, 'data.authapp_session', 'SELECT')
            OR has_table_privilege(r.rolname, 'data.authapp_session', 'INSERT')
            OR has_table_privilege(r.rolname, 'data.authapp_session', 'UPDATE')
            OR has_table_privilege(r.rolname, 'data.authapp_session', 'DELETE'))
);

-- The converse: authapp holds privileges on this table and nothing else. It is
-- a session store credential, not a second way into the course data.
SELECT 1 / (
    SELECT (count(*) = 1)::int
    FROM (
        SELECT DISTINCT c.oid
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
          CROSS JOIN LATERAL aclexplode(c.relacl) a
          JOIN pg_roles g ON g.oid = a.grantee
         WHERE g.rolname = 'authapp'
           AND n.nspname NOT IN ('pg_catalog', 'information_schema')
    ) AS reachable
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
