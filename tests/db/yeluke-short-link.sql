-- Course short links (issue #408): data.short_link, api.short_links and
-- api.follow_short_link.
--
-- Sample data this file leans on: users 1 (abc123, student), 3 (klj39,
-- faculty), 4 (jlb325, ta) and 5 (crt43, observer).
SELECT *
FROM no_plan()
;
-- ---------------------------------------------------------------------------
-- Shape and privileges
-- ---------------------------------------------------------------------------
SELECT has_table('data', 'short_link', 'short_link table should store course short links')
; SELECT view_owner_is('api', 'short_links', 'api', 'api.short_links should be owned by the api role, or its RLS policy never applies')
; SELECT table_owner_is('data', 'short_link', 'yelukerest_migrator', 'data.short_link should be owned by the migrator, which also owns the resolver')
; SELECT table_privs_are('api', 'short_links', 'faculty', ARRAY['SELECT', 'DELETE'], 'faculty should hold SELECT and DELETE on the whole view, and column grants for the rest')
; SELECT table_privs_are('api', 'short_links', 'ta', ARRAY['SELECT', 'DELETE'], 'ta should hold SELECT and DELETE on the whole view, and column grants for the rest')
; SELECT table_privs_are('api', 'short_links', 'student', ARRAY[]::text[], 'student should be granted nothing on api.short_links')
; SELECT table_privs_are('api', 'short_links', 'anonymous', ARRAY[]::text[], 'anonymous should be granted nothing on api.short_links')
; SELECT table_privs_are('api', 'short_links', 'observer', ARRAY[]::text[], 'observer should be granted nothing on api.short_links')
; SELECT table_privs_are('api', 'short_links', 'app', ARRAY[]::text[], 'app should be granted nothing on api.short_links')
; SELECT table_privs_are('data', 'short_link', 'faculty', ARRAY[]::text[], 'faculty should be granted nothing on data.short_link')
; SELECT table_privs_are('data', 'short_link', 'anonymous', ARRAY[]::text[], 'anonymous should be granted nothing on data.short_link')
; SELECT
    ok(has_column_privilege('faculty', 'api.short_links', 'slug', 'INSERT')
    AND has_column_privilege('faculty', 'api.short_links', 'url', 'INSERT')
    AND has_column_privilege('faculty', 'api.short_links', 'slug', 'UPDATE')
    AND has_column_privilege('faculty', 'api.short_links', 'url', 'UPDATE'), 'faculty may insert and update slug and url')
; SELECT
    ok(has_column_privilege('ta', 'api.short_links', 'slug', 'INSERT')
    AND has_column_privilege('ta', 'api.short_links', 'url', 'INSERT')
    AND has_column_privilege('ta', 'api.short_links', 'slug', 'UPDATE')
    AND has_column_privilege('ta', 'api.short_links', 'url', 'UPDATE'), 'ta may insert and update slug and url')
; SELECT is_empty('
        SELECT r.rolname || '' '' || c.col || '' '' || p.privilege
        FROM pg_roles r
        CROSS JOIN (VALUES (''created_by_user_id''), (''created_at''), (''updated_at'')) c(col)
        CROSS JOIN (VALUES (''INSERT''), (''UPDATE'')) p(privilege)
        WHERE r.rolname IN (''faculty'', ''ta'', ''student'', ''anonymous'', ''observer'', ''app'')
          AND has_column_privilege(r.oid, ''api.short_links'', c.col, p.privilege)
    ', 'no application role may write the audit columns')
;
-- ---------------------------------------------------------------------------
-- Slug and URL bounds
-- ---------------------------------------------------------------------------
-- Written against the base table as the test superuser: these are constraints
-- and hold whoever is asking.
SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''rnn'', ''https://colab.research.google.com/drive/abc'') ', 'a lowercase slug and an https URL are accepted')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''0-week-2'', ''https://example.com'') ', 'a slug may start with a digit and contain hyphens, and a URL may be a bare host')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''a'' || repeat(''b'', 39), ''https://example.com/?q=1#x'') ', 'a 40-character slug is accepted')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''a'' || repeat(''b'', 40), ''https://example.com'') ', '23514', NULL, 'a 41-character slug is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES ('''', ''https://example.com'') ', '23514', NULL, 'an empty slug is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''-rnn'', ''https://example.com'') ', '23514', NULL, 'a slug may not start with a hyphen')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''RNN'', ''https://example.com'') ', '23514', NULL, 'a slug may not contain uppercase letters')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''a_b'', ''https://example.com'') ', '23514', NULL, 'a slug may not contain an underscore')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''a.b'', ''https://example.com'') ', '23514', NULL, 'a slug may not contain a dot')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''a/b'', ''https://example.com'') ', '23514', NULL, 'a slug is a single path segment')
; SELECT throws_ok(E' INSERT INTO data.short_link (slug, url) VALUES (E''rnn\\n'', ''https://example.com'') ', '23514', NULL, 'a slug may not end in a newline')
; SELECT is_empty('
        SELECT reserved
        FROM unnest(ARRAY[''rest'', ''auth'', ''cas'', ''mcp'', ''oauth2'', ''userinfo'', ''openapi'']) reserved
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = ''data.short_link''::regclass
              AND conname = ''short_link_slug_not_reserved''
              AND pg_get_constraintdef(oid) LIKE ''%'''''' || reserved || ''''''%''
        )
    ', 'every reserved route is named by the reserved-slug constraint')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''rest'', ''https://example.com'') ', '23514', NULL, 'rest is reserved')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''auth'', ''https://example.com'') ', '23514', NULL, 'auth is reserved')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''cas'', ''https://example.com'') ', '23514', NULL, 'cas is reserved')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''mcp'', ''https://example.com'') ', '23514', NULL, 'mcp is reserved')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''oauth2'', ''https://example.com'') ', '23514', NULL, 'oauth2 is reserved')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''userinfo'', ''https://example.com'') ', '23514', NULL, 'userinfo is reserved')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''openapi'', ''https://example.com'') ', '23514', NULL, 'openapi is reserved')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''rest-of-term'', ''https://example.com'') ', 'a slug that merely starts with a reserved name is accepted')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u1'', ''http://example.com'') ', '23514', NULL, 'an http URL is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u2'', ''javascript:alert(1)'') ', '23514', NULL, 'a javascript URL is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u3'', ''https://'') ', '23514', NULL, 'an https URL with no host is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u4'', ''https:///path'') ', '23514', NULL, 'an https URL with an empty host is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u5'', ''//example.com'') ', '23514', NULL, 'a scheme-relative URL is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h1'', ''https://user@/path'') ', '23514', NULL, 'userinfo with no host is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h2'', ''https://:443/path'') ', '23514', NULL, 'a port with no host is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h3'', ''https://user@example.com/'') ', '23514', NULL, 'userinfo before a real host is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h4'', ''https://course.example@evil.example/'') ', '23514', NULL, 'a host-shaped userinfo is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h5'', ''https://-bad.example/'') ', '23514', NULL, 'a label may not start with a hyphen')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h6'', ''https://bad-.example/'') ', '23514', NULL, 'a label may not end with a hyphen')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h7'', ''https://example..com/'') ', '23514', NULL, 'a hostname may not have an empty label')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h8'', ''https://.example.com/'') ', '23514', NULL, 'a hostname may not start with a dot')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h9'', ''https://example.com:/'') ', '23514', NULL, 'a colon needs a port')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h10'', ''https://example.com:123456/'') ', '23514', NULL, 'a port has at most five digits')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h14'', ''https://example.com:65536/'') ', '23514', NULL, 'a port above 65535 is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h15'', ''https://example.com:0/'') ', '23514', NULL, 'port 0 is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h16'', ''https://example.com:0443/'') ', '23514', NULL, 'a port may not have a leading zero')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h17'', ''https://example.com../'') ', '23514', NULL, 'a hostname may have at most one trailing dot')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h18'', ''https://999.999.999.999/'') ', '23514', NULL, 'an all-digit dotted host is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h19'', ''https://10.0.0.1:8443/'') ', '23514', NULL, 'an IPv4 host with a port is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h11'', ''https://example.com:80a/'') ', '23514', NULL, 'a port is digits')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h12'', ''https://[::1]/'') ', '23514', NULL, 'an IPv6 literal is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''h13'', ''https://exa_mple.com/'') ', '23514', NULL, 'an underscore is not a hostname character')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok1'', ''https://colab.research.google.com/drive/1IO9z9RzF978e5ZATcilrM0bYNquJo6wM'') ', 'the real Colab URL is accepted')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok2'', ''https://example.com:8443/path'') ', 'a port is accepted')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok3'', ''https://Example.COM?q=a@b&r=1'') ', 'a query straight after the host, with an @ in it, is accepted')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok4'', ''https://example.com#section-2'') ', 'a fragment straight after the host is accepted')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok5'', ''https://a-b.c-d.example/x/@y'') ', 'internal hyphens, and an @ in the path, are accepted')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok6'', ''https://192.0.2.10/'') ', '23514', NULL, 'an IPv4 host is refused: the last label must contain a letter')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok7'', ''https://example.com:65535/'') ', 'port 65535 is accepted')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok8'', ''https://example.com:1/'') ', 'port 1 is accepted')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok9'', ''https://example.com./path'') ', 'one trailing dot after the hostname is accepted')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok10'', ''https://example.com.:8443/'') ', 'a trailing dot before a port is accepted')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok11'', ''https://1password.com/'') ', 'labels may start with a digit')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''ok12'', ''https://localhost/'') ', 'a single-label hostname is accepted')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u6'', ''HTTPS://example.com'') ', '23514', NULL, 'the scheme must be lowercase https')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u7'', ''https://exa mple.com'') ', '23514', NULL, 'a URL with a space is refused')
; SELECT throws_ok(E' INSERT INTO data.short_link (slug, url) VALUES (''u8'', E''https://example.com/\\tx'') ', '23514', NULL, 'a URL with a tab is refused')
; SELECT throws_ok(E' INSERT INTO data.short_link (slug, url) VALUES (''u9'', E''https://example.com/\\r\\nSet-Cookie: a=b'') ', '23514', NULL, 'a URL with CR or LF is refused, so it cannot split the Location header')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u10'', ''https://example.com/'' || chr(127)) ', '23514', NULL, 'a URL with a control character is refused')
; SELECT throws_ok(E' INSERT INTO data.short_link (slug, url) VALUES (''u11'', E''https://example.com\\\\@evil.example'') ', '23514', NULL, 'a URL with a backslash is refused')
; SELECT lives_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u12'', ''https://example.com/'' || repeat(''a'', 2028)) ', 'a 2048-byte URL is accepted')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u13'', ''https://example.com/'' || repeat(''a'', 2029)) ', '23514', NULL, 'a 2049-byte URL is refused')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u14'', ''https://example.com/'' || repeat(''é'', 1015)) ', '23514', NULL, 'the URL bound counts bytes, not characters')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''u15'', NULL) ', '23502', NULL, 'a link needs a URL')
; SELECT throws_ok(' INSERT INTO data.short_link (slug, url) VALUES (''rnn'', ''https://example.com/other'') ', '23505', NULL, 'a slug names one link')
;
-- ---------------------------------------------------------------------------
-- Staff CRUD through the view
-- ---------------------------------------------------------------------------
DELETE FROM data.short_link
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT results_eq('
        INSERT INTO api.short_links (slug, url)
        VALUES (''rnn'', ''https://colab.research.google.com/drive/rnn'')
        RETURNING slug, url, created_by_user_id, updated_at >= created_at
    ', ' VALUES (''rnn''::text, ''https://colab.research.google.com/drive/rnn''::text, 3, true) ', 'faculty creates a link and is recorded as its creator')
; SELECT results_eq(' SELECT slug FROM api.short_links ', ' VALUES (''rnn''::text) ', 'faculty reads links')
; SELECT results_eq('
        UPDATE api.short_links SET url = ''https://colab.research.google.com/drive/rnn-v2''
        WHERE slug = ''rnn''
        RETURNING url, created_by_user_id
    ', ' VALUES (''https://colab.research.google.com/drive/rnn-v2''::text, 3) ', 'faculty changes a link; its creator is unchanged')
; SELECT results_eq('
        INSERT INTO api.short_links (slug, url)
        VALUES (''rnn'', ''https://colab.research.google.com/drive/rnn-v3'')
        ON CONFLICT (slug) DO UPDATE SET url = EXCLUDED.url
        RETURNING url
    ', ' VALUES (''https://colab.research.google.com/drive/rnn-v3''::text) ', 'faculty upserts a link by slug')
; SELECT throws_ok(' INSERT INTO api.short_links (slug, url, created_by_user_id) VALUES (''forged'', ''https://example.com'', 4) ', '42501', NULL, 'faculty cannot name someone else as a link''s creator')
; SELECT throws_ok(' INSERT INTO api.short_links (slug, url, created_at) VALUES (''backdated'', ''https://example.com'', ''2020-01-01'') ', '42501', NULL, 'faculty cannot backdate a link')
; SELECT throws_ok(' UPDATE api.short_links SET created_by_user_id = 4 WHERE slug = ''rnn'' ', '42501', NULL, 'faculty cannot rewrite a link''s creator')
; SELECT throws_ok(' UPDATE api.short_links SET updated_at = ''2020-01-01'' WHERE slug = ''rnn'' ', '42501', NULL, 'faculty cannot set updated_at')
; SELECT throws_ok(' INSERT INTO api.short_links (slug, url) VALUES (''rest'', ''https://example.com'') ', '23514', NULL, 'the slug constraints hold through the view')
; SET LOCAL role TO ta
; SET "request.jwt.claim.role" TO ta
; SET "request.jwt.claim.user_id" TO "4"
; SELECT results_eq('
        INSERT INTO api.short_links (slug, url)
        VALUES (''embeddings'', ''https://colab.research.google.com/drive/emb'')
        RETURNING created_by_user_id
    ', ' VALUES (4) ', 'a TA creates a link and is recorded as its creator')
; SELECT set_eq(' SELECT slug FROM api.short_links ', ARRAY['rnn', 'embeddings'], 'a TA reads every link, faculty''s included')
; SELECT results_eq('
        UPDATE api.short_links SET url = ''https://example.com/rnn''
        WHERE slug = ''rnn''
        RETURNING url, created_by_user_id
    ', ' VALUES (''https://example.com/rnn''::text, 3) ', 'a TA changes a link faculty made; faculty stays its creator')
; SELECT results_eq(' SELECT url FROM api.short_links WHERE slug = ''rnn'' ', ' VALUES (''https://example.com/rnn''::text) ', 'the TA''s change is what a later read sees')
; SELECT results_eq(' DELETE FROM api.short_links WHERE slug = ''embeddings'' RETURNING slug ', ' VALUES (''embeddings''::text) ', 'a TA deletes a link')
; SELECT throws_ok(' UPDATE api.short_links SET created_at = ''2020-01-01'' WHERE slug = ''rnn'' ', '42501', NULL, 'a TA cannot set created_at')
;
-- A TA write is bounded per request like every other TA-writable table.
SELECT throws_ok('
        INSERT INTO api.short_links (slug, url)
        SELECT ''bulk-'' || g, ''https://example.com/'' || g FROM generate_series(1, 65) g
    ', 'PT400', NULL, 'a TA request may not create more than 64 links')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SET "request.jwt.claim.user_id" TO "3"
; SELECT lives_ok('
        INSERT INTO api.short_links (slug, url)
        SELECT ''bulk-'' || g, ''https://example.com/'' || g FROM generate_series(1, 65) g
    ', 'faculty are not bounded')
; SELECT lives_ok(' DELETE FROM api.short_links WHERE slug LIKE ''bulk-%'' ', 'faculty delete links')
;
-- The policy keys on the request claim, not on the database role: a staff
-- grant presenting a student claim sees and writes nothing.
SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT is_empty(' SELECT slug FROM api.short_links ', 'a student claim reads no links even through a staff grant')
; SELECT throws_ok(' INSERT INTO api.short_links (slug, url) VALUES (''student-link'', ''https://example.com'') ', '42501', NULL, 'a student claim cannot create a link even through a staff grant')
;
-- ---------------------------------------------------------------------------
-- Everyone else is denied the view
-- ---------------------------------------------------------------------------
SET LOCAL role TO student
; SET "request.jwt.claim.role" TO student
; SET "request.jwt.claim.user_id" TO "1"
; SELECT throws_ok(' SELECT slug FROM api.short_links ', '42501', NULL, 'a student cannot read links')
; SELECT throws_ok(' INSERT INTO api.short_links (slug, url) VALUES (''student-link'', ''https://example.com'') ', '42501', NULL, 'a student cannot create a link')
; SELECT throws_ok(' UPDATE api.short_links SET url = ''https://example.com'' WHERE slug = ''rnn'' ', '42501', NULL, 'a student cannot change a link')
; SELECT throws_ok(' DELETE FROM api.short_links WHERE slug = ''rnn'' ', '42501', NULL, 'a student cannot delete a link')
; SELECT throws_ok(' SELECT api.follow_short_link(''rnn'') ', '42501', NULL, 'a student credential cannot call the resolver; Caddy follows links as anonymous')
; SET LOCAL role TO observer
; SET "request.jwt.claim.role" TO observer
; SET "request.jwt.claim.user_id" TO "5"
; SELECT throws_ok(' SELECT slug FROM api.short_links ', '42501', NULL, 'an observer cannot read links')
; SELECT throws_ok(' INSERT INTO api.short_links (slug, url) VALUES (''observer-link'', ''https://example.com'') ', '42501', NULL, 'an observer cannot create a link')
; SET LOCAL role TO app
; SET "request.jwt.claim.role" TO app
; SET "request.jwt.claim.user_id" TO ''
; SELECT throws_ok(' SELECT slug FROM api.short_links ', '42501', NULL, 'an app cannot read links')
; SELECT throws_ok(' DELETE FROM api.short_links ', '42501', NULL, 'an app cannot delete links')
; SELECT throws_ok(' SELECT api.follow_short_link(''rnn'') ', '42501', NULL, 'an app credential cannot call the resolver')
; SET LOCAL role TO faculty
; SET "request.jwt.claim.role" TO faculty
; SELECT throws_ok(' SELECT api.follow_short_link(''rnn'') ', '42501', NULL, 'a faculty credential cannot call the resolver')
; SET LOCAL role TO anonymous
; SET "request.jwt.claim.role" TO ''
; SET "request.jwt.claim.user_id" TO ''
; SELECT throws_ok(' SELECT slug FROM api.short_links ', '42501', NULL, 'anonymous cannot read links')
; SELECT throws_ok(' INSERT INTO api.short_links (slug, url) VALUES (''anon-link'', ''https://example.com'') ', '42501', NULL, 'anonymous cannot create a link')
; SELECT throws_ok(' DELETE FROM api.short_links ', '42501', NULL, 'anonymous cannot delete links')
;
-- ---------------------------------------------------------------------------
-- Following a link: anonymous, in the read-only transaction PostgREST opens
-- for a GET
-- ---------------------------------------------------------------------------
-- Last in the file, because a transaction cannot go back to read-write.
SET LOCAL transaction_read_only TO ON
; SELECT "is"(current_setting('transaction_read_only'), 'on', 'the resolver checks below run read-only')
; SELECT lives_ok(' SELECT api.follow_short_link(''rnn'') ', 'anonymous follows a link inside a read-only transaction')
; SELECT "is"(current_setting('response.status'), '302', 'a hit answers 302')
; SELECT "is"(current_setting('response.headers')::jsonb, '[{"Location": "https://example.com/rnn"}, {"Cache-Control": "no-store"}]'::jsonb, 'a hit sends Location and Cache-Control: no-store')
; SELECT lives_ok(' SELECT api.follow_short_link(''no-such-link'') ', 'anonymous follows an unknown link')
; SELECT "is"(current_setting('response.status'), '404', 'a miss answers 404')
; SELECT "is"(current_setting('response.headers')::jsonb, '[{"Cache-Control": "no-store"}]'::jsonb, 'a miss sends Cache-Control: no-store and no Location')
; SELECT lives_ok(' SELECT api.follow_short_link(NULL) ', 'a NULL slug is a miss, not an error')
; SELECT "is"(current_setting('response.status'), '404', 'a NULL slug answers 404')
; SELECT *
FROM finish()
