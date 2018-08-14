START TRANSACTION;

SET search_path = data, pg_catalog;

ALTER TABLE quiz
	DROP CONSTRAINT quiz_meeting_id_fkey;

ALTER TABLE quiz
	ALTER COLUMN duration DROP DEFAULT;

ALTER TABLE quiz
	ADD CONSTRAINT quiz_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES data.meeting(id) ON DELETE CASCADE;

COMMIT TRANSACTION;
