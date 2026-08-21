-- Revert add-user-api-token. Additive migration, so a clean drop.
DROP FUNCTION IF EXISTS api.exchange_user_api_token(TEXT);
DROP FUNCTION IF EXISTS api.create_user_api_token(TEXT, TEXT[], TIMESTAMP WITH TIME ZONE);
DROP FUNCTION IF EXISTS auth.sign_user_jwt_with_scopes(INT, data.user_role, TEXT, TEXT, TEXT);
DROP VIEW IF EXISTS api.user_api_tokens;
DROP TABLE IF EXISTS data.user_api_token;

CREATE OR REPLACE VIEW api.platform_version AS
    SELECT
        'yelukerest'::text AS platform,
        1::integer AS platform_compatibility_version,
        6::integer AS schema_compatibility_version,
        9::integer AS admin_api_version;
ALTER VIEW api.platform_version OWNER TO api;

NOTIFY pgrst, 'reload schema';
