-- Revert add-user-api-token. Additive migration, so a clean drop.
DROP FUNCTION IF EXISTS api.exchange_user_api_token(text)
; DROP FUNCTION IF EXISTS api.create_user_api_token(text, text[], timestamp with time zone)
; DROP FUNCTION IF EXISTS auth.sign_user_jwt_with_scopes(int, data.user_role, text, text, text)
; DROP VIEW IF EXISTS api.user_api_tokens
; DROP TABLE IF EXISTS data.user_api_token
; CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::int AS platform_compatibility_version,
        6::int AS schema_compatibility_version, 9::int AS admin_api_version
; ALTER VIEW api.platform_version
    OWNER TO api
; NOTIFY pgrst, 'reload schema'
