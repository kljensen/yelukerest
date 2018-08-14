START TRANSACTION;

SET search_path = data, pg_catalog;

ALTER TABLE quiz
	DROP CONSTRAINT quiz_meeting_id_fkey;

ALTER TABLE quiz
	ALTER COLUMN duration SET DEFAULT '00:15:00'::interval;

ALTER TABLE quiz
	ADD CONSTRAINT quiz_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES data.meeting(id) ON UPDATE CASCADE ON DELETE CASCADE;

COMMIT TRANSACTION;
