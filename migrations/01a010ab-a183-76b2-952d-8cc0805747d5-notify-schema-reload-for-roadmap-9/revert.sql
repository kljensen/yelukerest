-- Reverting a notification is itself a notification: PostgREST should be told
-- again, so its cache matches whatever the revert left behind.
NOTIFY pgrst, 'reload schema';
