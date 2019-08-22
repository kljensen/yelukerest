-- Revert yelukerest:quiz_slugs from pg

BEGIN;


ALTER TABLE data.quiz_question DROP COLUMN slug;
ALTER TABLE data.quiz_question_option DROP COLUMN slug;

COMMIT;
