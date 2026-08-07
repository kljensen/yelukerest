-- Audited, scope-aware internal-JWT minting for the MCP token exchange
-- (issue #263, ADR 0001). The mcpapp service validates external
-- bearer/OAuth tokens and exchanges the verified identity for a short
-- internal user JWT via issue_user_jwt_for_mcp below. This path is
-- deliberately separate from api.issue_user_jwt (authapp's credential)
-- so either service credential can be revoked independently.

-- Faculty-only view over the append-only mint audit history. Row access
-- is enforced by the RLS policy on data.mcp_jwt_mint_event.
CREATE OR REPLACE VIEW mcp_jwt_mint_events AS
    SELECT * FROM data.mcp_jwt_mint_event;

ALTER VIEW mcp_jwt_mint_events OWNER TO api;

-- A user's record of applications they have disconnected (issue #277).
-- Row access is enforced by the RLS policy on data.mcp_grant_revocation:
-- a student sees their own, faculty see all.
CREATE OR REPLACE VIEW mcp_grant_revocations AS
    SELECT * FROM data.mcp_grant_revocation;

ALTER VIEW mcp_grant_revocations OWNER TO api;

-- Mint-rate anomaly report: one caller credential minting tokens for
-- unusually many distinct subjects in a short window is the signature
-- of a compromised minting credential (see the ADR threat model). Rows
-- appear only when a caller minted tokens for more than 10 distinct
-- users within a single 10-minute window — comfortably above normal
-- traffic for a single mcpapp instance serving individual token
-- exchanges, and small enough to flag bulk impersonation quickly.
-- Tune by editing the threshold below. Faculty query this directly
-- (e.g. /rest/mcp_jwt_mint_events pages the raw history; this view is
-- the alarm). The underlying RLS policy makes it faculty-only.
-- Sliding 10-minute window: for every mint, count the distinct subjects
-- that same caller minted for in the preceding 10 minutes. Fixed epoch
-- buckets would miss a burst that straddles a bucket boundary (six
-- subjects at 00:09 plus six at 00:11 is twelve in two minutes but
-- fewer than the threshold in either bucket).
CREATE OR REPLACE VIEW mcp_jwt_mint_anomalies AS
    SELECT
        e.caller_app_name,
        e.created_at AS window_end,
        e.created_at - interval '10 minutes' AS window_start,
        (
            SELECT count(DISTINCT p.user_id)
            FROM data.mcp_jwt_mint_event p
            WHERE p.caller_app_name = e.caller_app_name
              AND p.created_at > e.created_at - interval '10 minutes'
              AND p.created_at <= e.created_at
        ) AS distinct_subjects,
        (
            SELECT count(*)
            FROM data.mcp_jwt_mint_event p
            WHERE p.caller_app_name = e.caller_app_name
              AND p.created_at > e.created_at - interval '10 minutes'
              AND p.created_at <= e.created_at
        ) AS mint_count
    FROM data.mcp_jwt_mint_event e
    WHERE (
        SELECT count(DISTINCT p.user_id)
        FROM data.mcp_jwt_mint_event p
        WHERE p.caller_app_name = e.caller_app_name
          AND p.created_at > e.created_at - interval '10 minutes'
          AND p.created_at <= e.created_at
    ) > 10;

ALTER VIEW mcp_jwt_mint_anomalies OWNER TO api;

-- Mint a short-lived (10 minute), scope-carrying internal user JWT for
-- the MCP service and record an append-only audit row in the same
-- transaction.
--
--   * Admits ONLY a validated service JWT with app_name=mcpapp
--     (mirrors the authapp check in api.issue_user_jwt); every other
--     caller gets insufficient_privilege.
--   * The set of roles that may be minted for is an allowlist read
--     from the course setting `mcp_mintable_roles` (comma-separated
--     role names), defaulting to student,ta,faculty. Faculty are
--     included by default because the pilot runs on faculty accounts;
--     the course operator can tighten this at any time with e.g.
--       select settings.set('mcp_mintable_roles', 'student,ta');
--     Observers are never mintable unless explicitly listed.
--   * p_scopes becomes a space-separated `scopes` claim (OAuth scope
--     convention) that PostgREST exposes via request.jwt.claims.
--   * p_external carries the already-verified external token identity
--     ('iss', 'sub', 'jti', 'client_id' keys; all optional) purely for
--     the audit trail. It grants nothing.
--   * An unknown netid returns an empty result (like issue_user_jwt);
--     a known netid whose role is not allowlisted raises
--     insufficient_privilege so mcpapp can distinguish policy refusals.
CREATE OR REPLACE FUNCTION issue_user_jwt_for_mcp(
    p_netid text,
    p_scopes text[],
    p_external jsonb DEFAULT NULL
) RETURNS TABLE (jwt text, user_id integer, netid text, "role" text)
SECURITY DEFINER
LANGUAGE plpgsql
SET search_path = pg_catalog, api, auth, data, request, settings, pg_temp
AS $$
DECLARE
    target_user data."user"%ROWTYPE;
    allowed_roles text[];
    scopes_text text;
    token_jti text;
    signed_jwt text;
BEGIN
    -- Admit only the mcpapp service credential.
    IF NOT (request.user_role() = 'app' AND request.app_name() = 'mcpapp') THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'only the mcpapp service may mint MCP user JWTs';
    END IF;

    IF p_netid IS NULL OR p_netid = '' OR char_length(p_netid) >= 100 THEN
        RAISE EXCEPTION 'invalid netid' USING ERRCODE = '22023';
    END IF;

    -- Scopes are mandatory at mint time: consumers treat a missing or
    -- empty scopes claim as read-only at most (default-deny), but the
    -- mint path still insists on an explicit grant.
    IF p_scopes IS NULL OR cardinality(p_scopes) = 0 OR cardinality(p_scopes) > 16 THEN
        RAISE EXCEPTION 'between 1 and 16 scopes are required' USING ERRCODE = '22023';
    END IF;
    -- NULL elements must be rejected explicitly: `scope !~ pattern` is
    -- NULL (not true) for a NULL element, so a NULL would pass the
    -- pattern check and then be dropped silently by array_to_string,
    -- minting a token whose scopes differ from those requested.
    IF EXISTS (
        SELECT 1 FROM unnest(p_scopes) AS s(scope)
        WHERE s.scope IS NULL OR s.scope !~ '^[a-z][a-z0-9._:-]{0,63}$'
    ) THEN
        RAISE EXCEPTION 'malformed scope' USING ERRCODE = '22023';
    END IF;

    SELECT u.* INTO target_user
    FROM data."user" u
    WHERE u.netid = p_netid;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    allowed_roles := string_to_array(
        coalesce(settings.get('mcp_mintable_roles'), 'student,ta,faculty'),
        ','
    );
    IF NOT (target_user.role::text = ANY (allowed_roles)) THEN
        RAISE insufficient_privilege
            USING MESSAGE = format('users with role %s are not mintable for MCP', target_user.role);
    END IF;

    -- Disconnect has to mean something (issue #277). Revoking consent at
    -- Hydra kills the refresh token at once, but an access token already
    -- issued keeps verifying offline against the JWKS, so the only place left
    -- to stop it is here: mcpapp must come back for a fresh internal
    -- credential every few minutes, and this refuses to give it one.
    --
    -- The comparison is against the external token's issued-at, not simply
    -- "a revocation exists", so that reconnecting works. A token minted after
    -- the revocation comes from a new authorization the user just granted;
    -- one minted before it is the grant they cut off.
    --
    -- iat has one-second granularity, so a token issued in the same second as
    -- the revocation is ambiguous. It is treated as revoked (>=, not >),
    -- which errs toward refusing access rather than keeping it: the cost is
    -- that a reconnection completed inside the same second is refused and the
    -- user must click again, while the alternative would let a token issued
    -- at the moment of disconnect keep working for its full hour.
    --
    -- The five-second allowance is for clock skew between the authorization
    -- server and this database. iat comes from Hydra's clock; revoked_at from
    -- Postgres's. If Hydra runs ahead, a token issued BEFORE the disconnect
    -- can carry an iat after it and would otherwise look like a fresh grant,
    -- which is a bypass lasting until that token expires. Widening the
    -- comparison closes it, at the cost of refusing a reconnection finished
    -- within five seconds of the disconnect. Five is generous for hosts that
    -- share an NTP source and small enough that a person clicking through a
    -- consent screen never notices; deployments where the two clocks can
    -- drift further than that need to fix the clocks (see docs/hydra.md).
    IF p_external ? 'client_id' AND p_external->>'client_id' <> '' THEN
        IF EXISTS (
            SELECT 1
            FROM data.mcp_grant_revocation r
            WHERE r.user_id = target_user.id
              AND r.client_id = p_external->>'client_id'
              AND r.revoked_at >= coalesce(
                  to_timestamp((p_external->>'iat')::double precision)
                      - interval '5 seconds',
                  '-infinity'::timestamptz
              )
        ) THEN
            RAISE insufficient_privilege
                USING MESSAGE = 'this application was disconnected; reconnect it to continue';
        END IF;
    END IF;

    token_jti := public.gen_random_uuid()::text;
    scopes_text := array_to_string(p_scopes, ' ');
    signed_jwt := auth.sign_mcp_user_jwt(
        target_user.id,
        target_user.role,
        target_user.netid,
        scopes_text,
        token_jti
    );

    -- Same-transaction audit: if this insert fails, no token escapes.
    INSERT INTO data.mcp_jwt_mint_event (
        user_id,
        netid,
        user_role,
        scopes,
        jti,
        caller_app_name,
        external_issuer,
        external_sub,
        external_jti,
        external_client_id
    )
    VALUES (
        target_user.id,
        target_user.netid,
        target_user.role::text,
        scopes_text,
        token_jti,
        request.app_name(),
        p_external->>'iss',
        p_external->>'sub',
        p_external->>'jti',
        p_external->>'client_id'
    );

    RETURN QUERY SELECT signed_jwt, target_user.id, target_user.netid, target_user.role::text;
END;
$$;

REVOKE ALL PRIVILEGES ON FUNCTION issue_user_jwt_for_mcp(text, text[], jsonb) FROM PUBLIC;

-- Record that a user disconnected an application (issue #277).
--
-- SECURITY DEFINER, and admitting only authapp's service credential, for the
-- same reason issue_user_jwt_for_mcp does: the caller is a service acting on a
-- browser session it has already authenticated, so the trust boundary is the
-- credential, and the function resolves the netid to a real user itself rather
-- than believing a user_id it was handed.
CREATE OR REPLACE FUNCTION record_mcp_grant_revocation(
    netid text,
    client_id text,
    client_name text DEFAULT NULL,
    scopes text DEFAULT NULL
) RETURNS TABLE (revoked_at timestamptz)
SECURITY DEFINER
LANGUAGE plpgsql
SET search_path = pg_catalog, api, auth, data, request, settings, pg_temp
AS $$
DECLARE
    target_user data."user"%ROWTYPE;
    recorded timestamptz;
BEGIN
    IF NOT (request.user_role() = 'app' AND request.app_name() = 'authapp') THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'only the authapp service may record a grant revocation';
    END IF;

    IF client_id IS NULL OR client_id = '' OR char_length(client_id) > 500 THEN
        RAISE EXCEPTION 'a client_id is required' USING ERRCODE = '22023';
    END IF;

    SELECT u.* INTO target_user FROM data."user" u WHERE u.netid = record_mcp_grant_revocation.netid;
    IF NOT FOUND THEN
        -- Same posture as the mint path: an unknown netid is an empty result,
        -- not an error that would confirm which netids exist.
        RETURN;
    END IF;

    INSERT INTO data.mcp_grant_revocation (user_id, netid, client_id, client_name, scopes)
    VALUES (
        target_user.id,
        target_user.netid,
        record_mcp_grant_revocation.client_id,
        left(record_mcp_grant_revocation.client_name, 500),
        left(record_mcp_grant_revocation.scopes, 1024)
    )
    RETURNING mcp_grant_revocation.revoked_at INTO recorded;

    RETURN QUERY SELECT recorded;
END;
$$;

REVOKE ALL PRIVILEGES ON FUNCTION record_mcp_grant_revocation(text, text, text, text) FROM PUBLIC;
