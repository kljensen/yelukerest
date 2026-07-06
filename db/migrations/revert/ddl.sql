-- Revert yelukerest:ddl from pg

BEGIN;

DO $$
BEGIN
    RAISE EXCEPTION 'Yelukerest bootstrap migrations are irreversible; rebuild or drop the disposable database instead.';
END $$;

COMMIT;
