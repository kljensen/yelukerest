-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.
-- Course short links as rows (issue #408).
--
-- A course's short links (www.<domain>/rnn -> a Colab notebook, say) have
-- been Caddy site blocks installed on the host by hand, so adding one needed
-- SSH and a reload. They live here instead: faculty and TAs write rows through
-- api.short_links, and Caddy sends a missing top-level path to
-- api.follow_short_link through PostgREST (issue #409), which answers with the
-- redirect. A new link is a data change.
--
-- Anyone may follow a link, so a slug and its destination are guessable and
-- public. Links are not confidential and nothing here treats them as such.
-- There is no click tracking: the resolver is read-only so it can run inside
-- the read-only transaction PostgREST opens for a GET.
-- ---------------------------------------------------------------------------
-- data.short_link
-- ---------------------------------------------------------------------------
-- created_by_user_id is NULL only for a row loaded outside the API, such as by
-- the migrator at cutover, where there is no request user; SET NULL so a link
-- outlives the account of whoever made it.
--
-- The slug is lowercase letters, digits and hyphens, one path segment. Caddy's
-- matcher (caddy/Caddyfile, `@short_link`) uses the same pattern; a slug this
-- accepted and Caddy refused would be a row nobody can follow. The reserved
-- names are the top-level routes Caddy serves itself. Their bare paths are
-- excluded from the short-link matcher, so a row named for one could never
-- resolve; refusing it here says so at write time.
--
-- The URL is https and its authority is a hostname of DNS labels (letters,
-- digits, internal hyphens, dot-separated), with at most one trailing dot and
-- an optional port from 1 to 65535 without leading zeros. The last label must
-- contain a letter, which refuses IPv4 addresses such as 10.0.0.1; bracketed
-- IPv6 is refused too, as course links never need an IP host. No userinfo:
-- an '@' in the authority is refused, so https://course.example@evil.example
-- cannot pass for a course link. This is a guard, not a URL parser: label
-- and hostname lengths are not checked. The URL becomes a Location header, so
-- it may carry no whitespace or control character (no header splitting) and
-- no backslash, which browsers read as a slash and which can make
-- https://example.com\@evil.example name a different host.
CREATE TABLE data.short_link (
    slug text PRIMARY KEY,
    url text NOT NULL,
    created_by_user_id int DEFAULT request.user_id() REFERENCES data."user" (id) ON DELETE SET NULL,
    created_at timestamp with time zone NOT NULL DEFAULT current_timestamp,
    updated_at timestamp with time zone NOT NULL DEFAULT current_timestamp,
    CONSTRAINT short_link_slug_shape CHECK (slug ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
    CONSTRAINT short_link_slug_not_reserved CHECK (slug <> ALL(ARRAY['rest', 'auth', 'cas', 'mcp', 'oauth2', 'userinfo', 'openapi'])),
    CONSTRAINT short_link_url_https_with_host CHECK (url ~ E'^https://([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.)*(?=[A-Za-z0-9-]*[A-Za-z])[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.?(:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?([/?#].*)?$'),
    CONSTRAINT short_link_url_max_bytes CHECK (octet_length(url) <= 2048),
    CONSTRAINT short_link_url_no_space_control_or_backslash CHECK (url !~ E'[[:space:][:cntrl:]\\\\]'),
    CONSTRAINT short_link_updated_after_created CHECK (updated_at >= created_at)
)
;
-- tests/db/foreign-key-indexes.sql requires an index led by every referencing
-- column.
CREATE INDEX short_link_created_by_user_id_idx
ON data.short_link USING btree (created_by_user_id)
; ALTER TABLE data.short_link
    OWNER TO yelukerest_migrator
; COMMENT ON TABLE data.short_link IS 'Course short links: a top-level path on the course site that redirects to a URL. Public once created.'
;
-- The generic updated_at trigger, already routed through data.touched_at.
CREATE TRIGGER tg_short_link_update_timestamps BEFORE INSERT OR UPDATE ON data.short_link FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column()
;
-- TAs can write here, so the table carries the statement row bound every
-- student- or TA-writable table carries (01a0481a, issue #346), at the default
-- of 64 rows per request. Faculty are exempt, as everywhere.
CREATE TRIGGER tg_short_link_row_bound_insert AFTER INSERT ON data.short_link REFERENCING NEW TABLE bounded_new_rows EXECUTE FUNCTION data.enforce_request_row_bound()
; CREATE TRIGGER tg_short_link_row_bound_update AFTER UPDATE ON data.short_link REFERENCING NEW TABLE bounded_new_rows EXECUTE FUNCTION data.enforce_request_row_bound()
; CREATE TRIGGER tg_short_link_row_bound_delete AFTER DELETE ON data.short_link REFERENCING OLD TABLE bounded_old_rows EXECUTE FUNCTION data.enforce_request_row_bound()
;
-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
-- Enabled, not forced: the resolver below is owned by the table owner and
-- reads every row as that owner, which is how an anonymous caller follows a
-- link it has no privilege to read.
ALTER TABLE data.short_link
    ENABLE ROW LEVEL SECURITY
; CREATE POLICY short_link_staff ON data.short_link TO api USING (request.user_role() IN ('faculty', 'ta')) WITH CHECK (request.user_role() IN ('faculty', 'ta'))
;
-- `api` is the view owner, so these bound what a write through the view can
-- reach. Only slug and url can be written; who made a link and when are
-- filled in by the default and the trigger.
GRANT select, delete ON data.short_link TO api
; GRANT insert (slug, url), update (slug, url) ON data.short_link TO api
;
-- ---------------------------------------------------------------------------
-- api.short_links
-- ---------------------------------------------------------------------------
-- Owned by `api` so the policy above governs reads and writes through it.
CREATE VIEW api.short_links AS
    SELECT slug, url, created_by_user_id, created_at, updated_at
    FROM data.short_link
; ALTER VIEW api.short_links
    OWNER TO api
; COMMENT ON VIEW api.short_links IS 'Course short links: /<slug> on the course site redirects to url. Faculty and TAs only; following a link needs no credential.'
; COMMENT ON COLUMN api.short_links.slug IS 'The path segment, such as rnn for /rnn: lowercase letters, digits and hyphens, at most 40 characters, not a reserved route'
; COMMENT ON COLUMN api.short_links.url IS 'The https destination; at most 2048 bytes, no whitespace, control characters or backslashes'
; COMMENT ON COLUMN api.short_links.created_by_user_id IS 'User who created the link; NULL when it was loaded outside the API or its creator was removed'
; COMMENT ON COLUMN api.short_links.created_at IS 'When the link was created'
; COMMENT ON COLUMN api.short_links.updated_at IS 'When the link was last changed'
; GRANT select, delete ON api.short_links TO faculty, ta
; GRANT insert (slug, url), update (slug, url) ON api.short_links TO faculty, ta
;
-- ---------------------------------------------------------------------------
-- api.follow_short_link
-- ---------------------------------------------------------------------------
-- Answers with the redirect itself through PostgREST's response.status and
-- response.headers, so Caddy only has to proxy the request. RETURNS void: the
-- body carries nothing. STABLE so PostgREST serves it to GET and HEAD, inside
-- the read-only transaction it opens for them; set_config is allowed there.
--
-- Executable by anonymous alone. Caddy strips Authorization before proxying,
-- so a signed-in visitor follows a link as anonymous too, and an expired
-- token cannot break it.
--
-- The column is qualified and the parameter read as $1, so `slug` is never
-- ambiguous between the two.
CREATE FUNCTION api.follow_short_link(slug text) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO pg_catalog, pg_temp AS $$
DECLARE
    destination text;
BEGIN
    SELECT l.url INTO destination FROM data.short_link l WHERE l.slug = $1;
    IF destination IS NULL THEN
        PERFORM set_config('response.status', '404', true);
        PERFORM set_config('response.headers',
            json_build_array(json_build_object('Cache-Control', 'no-store'))::text, true);
    ELSE
        PERFORM set_config('response.status', '302', true);
        PERFORM set_config('response.headers',
            json_build_array(
                json_build_object('Location', destination),
                json_build_object('Cache-Control', 'no-store')
            )::text, true);
    END IF;
END;
$$
; ALTER FUNCTION api.follow_short_link(text) OWNER TO yelukerest_migrator
; REVOKE ALL ON FUNCTION api.follow_short_link(text) FROM public
; GRANT execute ON FUNCTION api.follow_short_link(text) TO anonymous
; COMMENT ON FUNCTION api.follow_short_link(text) IS 'Follow a course short link: 302 to its url, or 404, both with Cache-Control: no-store. Anonymous only; Caddy calls it for a missing top-level path.'
;
-- ---------------------------------------------------------------------------
-- Tell PostgREST the API changed
-- ---------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema'
