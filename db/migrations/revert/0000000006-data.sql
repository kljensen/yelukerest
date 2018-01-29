START TRANSACTION;

SET search_path = api, pg_catalog;

DROP VIEW quiz_grades;

SET search_path = data, pg_catalog;

DROP FUNCTION fill_quiz_grade_defaults();

ALTER TABLE quiz
	DROP CONSTRAINT quiz_id_points_possible_key;

DROP TABLE quiz_grade;

COMMIT TRANSACTION;
