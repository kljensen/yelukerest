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

-- Disconnected-grant records (issue #277). A user reads their own so a
-- settings page can show what they have cut off; faculty read all for
-- support and audit. Nobody updates or deletes: the table carries an
-- append-only trigger, and the mint path reads these rows as fact when
-- deciding whether a grant is still live.
--
-- INSERT is granted to the app role because authapp records the revocation
-- in the same request that revokes consent at Hydra, under its own service
-- credential. The RLS policy below is what keeps that narrow: a row must
-- name the user it is about.
GRANT SELECT, INSERT ON data.mcp_grant_revocation TO api;
GRANT USAGE, SELECT ON SEQUENCE data.mcp_grant_revocation_id_seq TO api;

ALTER TABLE data.mcp_grant_revocation ENABLE ROW LEVEL SECURITY;

CREATE POLICY mcp_grant_revocation_access_policy
    ON data.mcp_grant_revocation TO api
USING (
    request.user_role() = 'faculty'
    OR request.user_id() = user_id
    -- The minting path checks this table through a SECURITY DEFINER
    -- function, but authapp reads it back as itself after writing.
    OR (request.user_role() = 'app' AND request.app_name() = 'authapp')
)
WITH CHECK (
    -- A service may only record a revocation that names a real user, and a
    -- person may only record one about themselves.
    (request.user_role() = 'app' AND request.app_name() = 'authapp')
    OR request.user_id() = user_id
    OR request.user_role() = 'faculty'
);

GRANT SELECT ON api.mcp_grant_revocations TO student, ta, faculty;
GRANT SELECT, INSERT ON api.mcp_grant_revocations TO app;

-- authapp records a disconnect through this RPC; the function admits only its
-- credential, so granting the app role EXECUTE does not let mcpapp use it.
GRANT EXECUTE ON FUNCTION api.record_mcp_grant_revocation(text, text, text, text) TO app;
