-- Undoes deploy.sql. Runs inside a transaction Zapadka opens and commits.
--
-- Additive migration, so a clean drop. Reverting destroys the record of what
-- each consuming app was allowed to read; this exists so the migration is
-- reversible, not as a routine operation.
DROP VIEW IF EXISTS api.api_grants
; DROP FUNCTION IF EXISTS api.revoke_api_grant(int)
; DROP FUNCTION IF EXISTS data.create_api_grant_rows(text, jsonb, timestamp with time zone, int)
; DROP TABLE IF EXISTS data.api_grant_assignment_field
; DROP TABLE IF EXISTS data.api_grant_assignment
; DROP TABLE IF EXISTS data.api_grant
; DROP FUNCTION IF EXISTS data.api_grant_permissions_are_immutable()
; DROP FUNCTION IF EXISTS data.api_grant_allows_only_first_revocation()
; NOTIFY pgrst, 'reload schema'
