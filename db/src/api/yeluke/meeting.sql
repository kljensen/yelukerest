create or replace view meetings as
    select * from data.meeting;

-- it is important to set the correct owner so the RLS policy kicks in
alter view meetings owner to api;

COMMENT ON VIEW meetings IS
    'An in-person meeting of our class, usually a lecture';
COMMENT ON COLUMN meetings.slug IS
    'A short identifier, appropriate for URLs, like "sql-intro"';
COMMENT ON COLUMN meetings.summary IS
    'A short description of the meeting in Markdown format';
COMMENT ON COLUMN meetings.description IS
    'A long description of the meeting in Markdown format';
COMMENT ON COLUMN meetings.begins_at IS
    'The time at which the meeting begins, including timezone';
COMMENT ON COLUMN meetings.duration IS
    'The duration of the meeting as a Postgres interval';
COMMENT ON COLUMN meetings.is_draft IS
    'An indicator of if the content is still changing';
COMMENT ON COLUMN meetings.created_at IS
    'The time this database entry was created, including timezone';
COMMENT ON COLUMN meetings.updated_at IS
    'The most recent time this database entry was updated, including timezone';