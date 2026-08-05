-- The mint audit table is written only by api.issue_user_jwt_for_mcp
-- (SECURITY DEFINER, superuser-owned), so the api role needs SELECT
-- only. Faculty read the history and the anomaly report; nobody edits
-- either (the table has an append-only trigger as well).
GRANT SELECT ON data.mcp_jwt_mint_event TO api;

ALTER TABLE data.mcp_jwt_mint_event ENABLE ROW LEVEL SECURITY;

CREATE POLICY mcp_jwt_mint_event_access_policy
    ON data.mcp_jwt_mint_event TO api
USING (
    request.user_role() = 'faculty'
);

GRANT SELECT ON api.mcp_jwt_mint_events TO faculty;
GRANT SELECT ON api.mcp_jwt_mint_anomalies TO faculty;

-- The app role may execute the minting RPC; inside the function only a
-- request JWT with app_name=mcpapp is admitted, so authapp's credential
-- (also role app) is rejected there. Revoking one service's grant or
-- credential never affects the other.
GRANT EXECUTE ON FUNCTION api.issue_user_jwt_for_mcp(text, text[], jsonb) TO app;
