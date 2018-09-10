START TRANSACTION;

SET search_path = api, pg_catalog;

DROP VIEW assignment_grade_distributions;

DROP VIEW quiz_grade_distributions;

COMMIT TRANSACTION;
