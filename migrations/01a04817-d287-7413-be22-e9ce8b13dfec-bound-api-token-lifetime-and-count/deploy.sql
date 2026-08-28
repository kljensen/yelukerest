-- Deployed inside a transaction Zapadka opens and commits.
-- Do not write BEGIN, COMMIT, ROLLBACK, or SAVEPOINT here.

-- Bound personal access tokens: a maximum lifetime, and a maximum number of
-- live ones per person (issue #347).
--
-- What was wrong: api.create_user_api_token validated only that p_expires_at
-- was in the future. Four months was the DEFAULT, never a bound, so an
-- ordinary student JWT could mint a submissions:write token expiring in 2031
-- in a single call. The token UI exposes no expiry field, so nobody clicking
-- through the site would do this -- but the RPC is granted directly to
-- `student`, and the whole point of the feature is that students point scripts
-- and AI assistants at it. "Make me a token that never expires" was one
-- documented parameter away, and nothing refused.
--
-- Nothing here changes the default. Four months stays four months. What
-- changes is that asking for more than 180 days is now refused rather than
-- granted, and that nobody accumulates an unbounded pile of live credentials.
--
-- Refuse, do not clamp. A caller that asked for five years and silently got
-- 180 days would go on believing it had five years, and would discover
-- otherwise at the least convenient moment. The error names the bound.

-- ---------------------------------------------------------------------------
-- Preflight: say what the new rules would catch before enforcing them
-- ---------------------------------------------------------------------------
-- Real tokens exist in production, so run this against the target BEFORE
-- deploying. It reports by prefix -- never by secret, which is not stored --
-- so a person can tell the affected students what changed, rather than having
-- them find out from a support request in four months' time.
--
--     SELECT token_prefix, user_id, name,
--            round(extract(epoch FROM expires_at - created_at) / 86400) AS days
--       FROM data.user_api_token
--      WHERE expires_at > created_at + interval '180 days'
--      ORDER BY expires_at DESC;
--
--     SELECT user_id, count(*) AS active
--       FROM data.user_api_token
--      WHERE revoked_at IS NULL AND expires_at > current_timestamp
--      GROUP BY user_id HAVING count(*) > 5
--      ORDER BY active DESC;
--
-- The DO block below is the same report, and it runs as part of the deploy --
-- but only a psql run of this file will show it. Verified against Zapadka
-- 0.4.1: `zapadka deploy` discards NOTICE and WARNING from user SQL, and its
-- --output json report carries neither. The copy-pasteable queries above are
-- therefore the preflight that is actually seen; the DO block is the backstop
-- for whoever runs this file by hand.
DO $$
DECLARE
    over_long INT;
    over_count INT;
    detail TEXT;
BEGIN
    SELECT count(*) INTO over_long
      FROM data.user_api_token
     WHERE expires_at > created_at + interval '180 days';

    SELECT count(*) INTO over_count
      FROM (
          SELECT user_id
            FROM data.user_api_token
           WHERE revoked_at IS NULL AND expires_at > current_timestamp
           GROUP BY user_id
          HAVING count(*) > 5
      ) s;

    IF over_long = 0 AND over_count = 0 THEN
        RAISE NOTICE 'user_api_token preflight: every token already satisfies the 180 day bound and the 5 active token cap';
    END IF;

    IF over_long > 0 THEN
        SELECT string_agg(
                   format('%s (user %s, %s days)',
                          token_prefix, user_id,
                          round(extract(epoch FROM expires_at - created_at) / 86400)),
                   ', ' ORDER BY expires_at DESC)
          INTO detail
          FROM data.user_api_token
         WHERE expires_at > created_at + interval '180 days';
        RAISE NOTICE 'user_api_token preflight: % token(s) exceed 180 days and will be capped at created_at + 180 days: %',
            over_long, detail;
    END IF;

    IF over_count > 0 THEN
        SELECT string_agg(format('user %s holds %s', user_id, n), ', ' ORDER BY n DESC)
          INTO detail
          FROM (
              SELECT user_id, count(*) AS n
                FROM data.user_api_token
               WHERE revoked_at IS NULL AND expires_at > current_timestamp
               GROUP BY user_id
              HAVING count(*) > 5
          ) s;
        RAISE NOTICE 'user_api_token preflight: % user(s) already hold more than 5 active tokens and will not be able to create another until they are under the cap: %',
            over_count, detail;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Existing data: cap the over-long, leave the over-numerous alone
-- ---------------------------------------------------------------------------
-- The lifetime bound is a table constraint, so rows that violate it have to be
-- brought into line or the constraint cannot be added. Capping at
-- created_at + 180 days keeps every token working; it only ends sooner than
-- its holder was told. That is a real, if small, harm, which is why the
-- preflight above names the prefixes.
UPDATE data.user_api_token
   SET expires_at = created_at + interval '180 days'
 WHERE expires_at > created_at + interval '180 days';

-- The count cap is deliberately NOT a table constraint, and no existing token
-- is revoked to satisfy it.
--
-- Revoking someone's oldest tokens would destroy credentials that are, as far
-- as we can tell, in use -- a script breaking at 3am with no explanation is a
-- worse outcome than the thing the cap exists to prevent. Failing the deploy
-- would be worse still: it would block a security fix on a data-cleanup task
-- nobody has scheduled, and the lifetime bound is the more urgent half.
--
-- So the cap is enforced only at creation time. Someone already over it keeps
-- every token they have and simply cannot mint another until revocation or
-- expiry brings them under five. The population converges on the policy
-- without anyone losing access.

ALTER TABLE data.user_api_token
    ADD CONSTRAINT user_api_token_max_lifetime
    CHECK (expires_at <= created_at + interval '180 days');

COMMENT ON CONSTRAINT user_api_token_max_lifetime ON data.user_api_token IS
    'Backstop for the 180 day bound. api.create_user_api_token refuses first, with a message that names the limit; this catches anything that reaches the table another way.';

-- ---------------------------------------------------------------------------
-- Creating a token, now bounded
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION api.create_user_api_token(
    p_name TEXT,
    p_scopes TEXT[] DEFAULT ARRAY['course:read', 'grades:read', 'submissions:read']::TEXT[],
    p_expires_at TIMESTAMP WITH TIME ZONE DEFAULT NULL
) RETURNS TABLE (id INT, token TEXT, token_prefix TEXT, name TEXT, scopes TEXT[], expires_at TIMESTAMP WITH TIME ZONE)
SECURITY DEFINER
LANGUAGE plpgsql
SET search_path = pg_catalog, api, auth, data, request, settings, public, pg_temp
AS $$
DECLARE
    -- Six months. Longer than the semester the credential is for, so a
    -- default-expiry token created in week one never runs into it, and short
    -- enough that a token forgotten on a laptop stops working inside the
    -- academic year rather than outliving the course.
    max_lifetime CONSTANT INTERVAL := interval '180 days';
    -- Enough for the machines a person actually uses -- laptop, notebook
    -- server, a project or two -- and few enough that the listing stays
    -- reviewable. The point of the listing is that `last_used_at` on an
    -- unfamiliar row is noticeable, and it stops being noticeable at forty
    -- rows.
    max_active CONSTANT INT := 5;
    caller_id INT;
    active_count INT;
    new_prefix TEXT;
    new_secret TEXT;
    new_expires TIMESTAMP WITH TIME ZONE;
    new_id INT;
BEGIN
    caller_id := request.user_id();
    IF caller_id IS NULL THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'a signed-in user is required to create an API token';
    END IF;

    IF p_name IS NULL OR char_length(trim(p_name)) = 0 OR char_length(p_name) > 100 THEN
        RAISE EXCEPTION 'a token name of 1 to 100 characters is required' USING ERRCODE = '22023';
    END IF;

    -- Default is read-only. submissions:write has to be asked for, matching the
    -- MCP consent page where the write scope starts unchecked.
    IF p_scopes IS NULL OR cardinality(p_scopes) = 0 THEN
        RAISE EXCEPTION 'at least one scope is required' USING ERRCODE = '22023';
    END IF;

    -- Four months by default: comfortably longer than a semester, so this is
    -- set up once and not thought about again. Length is not the control here;
    -- revocability is.
    new_expires := coalesce(p_expires_at, current_timestamp + interval '4 months');
    IF new_expires <= current_timestamp THEN
        RAISE EXCEPTION 'expires_at must be in the future' USING ERRCODE = '22023';
    END IF;

    -- One bound for every token, whatever its scopes.
    --
    -- Issue #347 asks whether a submissions:write token should get a shorter
    -- maximum than a read-only one, and the answer here is no -- not because
    -- the concern is wrong, but because a shorter write maximum cannot be
    -- expressed coherently while the four month default stands.
    --
    -- The default IS four months, for read and write alike, and the token page
    -- exposes no expiry field: every token a person creates in the browser
    -- takes it. A write maximum below four months would therefore refuse the
    -- product's own default path -- tick submissions:write, press Create, get
    -- an error, with no field to correct. A write maximum at or above four
    -- months only narrows the band between the default and 180 days, which is
    -- reachable solely by callers passing p_expires_at explicitly: a second
    -- rule and a second number to document, buying under two months on a
    -- credential that is revocable, listed, and stamped with last_used_at.
    --
    -- The change worth making for write tokens is a shorter DEFAULT, not a
    -- shorter maximum -- and that belongs with a UI that shows the expiry it
    -- chose. Revisit then.
    IF new_expires > current_timestamp + max_lifetime THEN
        RAISE EXCEPTION
            'expires_at may be at most % from now (% requested, latest allowed is %); create a shorter-lived token and renew it',
            max_lifetime, new_expires, current_timestamp + max_lifetime
            USING ERRCODE = '22023';
    END IF;

    -- Lock the caller's own user row before counting.
    --
    -- Without the lock two concurrent creates both read four active tokens and
    -- both insert, leaving six: the classic check-then-act race, and an easy
    -- one to hit because the callers here are scripts. The user row is the
    -- natural thing to lock -- one row per person, already there, and it
    -- serialises exactly the creates that contend, not everyone else's.
    PERFORM 1 FROM data."user" u WHERE u.id = caller_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE insufficient_privilege
            USING MESSAGE = 'the signed-in user no longer exists';
    END IF;

    -- Revoked and expired tokens do not count. A person who cleans up, or who
    -- simply waits, gets their slot back; the cap is on live credentials, not
    -- on lifetime history.
    SELECT count(*) INTO active_count
      FROM data.user_api_token t
     WHERE t.user_id = caller_id
       AND t.revoked_at IS NULL
       AND t.expires_at > current_timestamp;

    IF active_count >= max_active THEN
        RAISE EXCEPTION
            'you already have % active API tokens, which is the maximum of %; revoke one under Settings then API tokens before creating another',
            active_count, max_active
            USING ERRCODE = 'PT409';
    END IF;

    -- 4 bytes of prefix for identification, 32 bytes of secret for entropy.
    new_prefix := 'yk_' || encode(public.gen_random_bytes(4), 'hex');
    new_secret := encode(public.gen_random_bytes(32), 'hex');

    INSERT INTO data.user_api_token (user_id, token_prefix, token_hash, name, scopes, expires_at)
    VALUES (caller_id, new_prefix, sha256(new_secret::bytea), trim(p_name), p_scopes, new_expires)
    RETURNING data.user_api_token.id INTO new_id;

    RETURN QUERY SELECT
        new_id,
        new_prefix || '_' || new_secret,
        new_prefix,
        trim(p_name),
        p_scopes,
        new_expires;
END;
$$;

ALTER FUNCTION api.create_user_api_token(TEXT, TEXT[], TIMESTAMP WITH TIME ZONE)
    OWNER TO yelukerest_migrator;
REVOKE ALL PRIVILEGES ON FUNCTION api.create_user_api_token(TEXT, TEXT[], TIMESTAMP WITH TIME ZONE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_user_api_token(TEXT, TEXT[], TIMESTAMP WITH TIME ZONE)
    TO student, ta, faculty;

COMMENT ON FUNCTION api.create_user_api_token(TEXT, TEXT[], TIMESTAMP WITH TIME ZONE) IS
    'Create a personal access token for the calling user. Returns the secret exactly once; read-only scopes by default, four month expiry, 180 days maximum, five active tokens per person.';

NOTIFY pgrst, 'reload schema';
