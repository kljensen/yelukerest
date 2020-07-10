create or replace view grade_snapshots as
    select * from data.grade_snapshot;

-- It is important to set the correct owner so the RLS policy kicks in.
-- The `user` table should have RLS becuase students should not
-- see each others user grades.
alter view grade_snapshots owner to api;

COMMENT ON VIEW grade_snapshots IS
    'Snapshots of class grades at particular times';
COMMENT ON COLUMN grade_snapshots.slug IS
    'The slug, or unique identifier, of this grade snapshot';
COMMENT ON COLUMN grade_snapshots.description IS
    'The description of this grade snapshot. This might tell you how the grades were computed for this snapshot.';
COMMENT ON COLUMN grade_snapshots.created_at IS
    'When this snapshot was created';
COMMENT ON COLUMN grade_snapshots.updated_at IS
    'When this snapshot was last updated';