START TRANSACTION;

SET search_path = api, pg_catalog;

DROP VIEW assignment_grades;

SET search_path = data, pg_catalog;

DROP FUNCTION fill_assignment_grade_defaults();

ALTER TABLE assignment
	DROP CONSTRAINT assignment_slug_points_possible_key;

DROP TABLE assignment_grade;

COMMIT TRANSACTION;
