begin;
select plan(1);

WITH fk AS (
    SELECT
        c.oid,
        c.conrelid,
        c.conname,
        c.conkey::int2[] AS conkey
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE c.contype = 'f'
    AND n.nspname = 'data'
),
idx AS (
    SELECT
        ix.indrelid,
        string_to_array(ix.indkey::text, ' ')::int2[] AS indkey
    FROM pg_index ix
    JOIN pg_class i ON i.oid = ix.indexrelid
    JOIN pg_am am ON am.oid = i.relam
    WHERE ix.indisvalid
    AND ix.indisready
    AND ix.indpred IS NULL
    AND am.amname = 'btree'
),
missing AS (
    SELECT fk.oid
    FROM fk
    WHERE NOT EXISTS (
        SELECT 1
        FROM idx
        WHERE idx.indrelid = fk.conrelid
        AND idx.indkey[1:array_length(fk.conkey, 1)] = fk.conkey
    )
)
SELECT is(
    (SELECT count(*)::int FROM missing),
    0,
    'every data foreign key should have a plain btree index on its referencing columns'
);

select * from finish();
rollback;
