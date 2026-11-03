-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- Additive migration, so a clean drop. Reverting destroys every stored link;
-- export api.short_links first if they are still wanted.
DROP FUNCTION IF EXISTS api.follow_short_link(text)
; DROP VIEW IF EXISTS api.short_links
; DROP TABLE IF EXISTS data.short_link
; NOTIFY pgrst, 'reload schema'
