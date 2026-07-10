-- Verify yelukerest:data on pg

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'jwt_lifetime'
        AND value = '3600'
    ) THEN
        RAISE EXCEPTION 'missing jwt_lifetime setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'jwt_issuer'
        AND value = 'yelukerest'
    ) THEN
        RAISE EXCEPTION 'missing jwt_issuer setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'jwt_audience'
        AND value = 'yelukerest-postgrest'
    ) THEN
        RAISE EXCEPTION 'missing jwt_audience setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'auth.default-role'
        AND value = 'anonymous'
    ) THEN
        RAISE EXCEPTION 'missing auth.default-role setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'auth.data-schema'
        AND value = 'data'
    ) THEN
        RAISE EXCEPTION 'missing auth.data-schema setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'auth.api-schema'
        AND value = 'api'
    ) THEN
        RAISE EXCEPTION 'missing auth.api-schema setting';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM settings.secrets
        WHERE key = 'jwt_secret'
        AND value <> ''
    ) THEN
        RAISE EXCEPTION 'missing jwt_secret setting';
    END IF;
END $$;

ROLLBACK;
