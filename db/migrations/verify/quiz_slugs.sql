-- Verify yelukerest:quiz_slugs on pg

BEGIN;

SELECT slug from data.quiz_question;
SELECT slug from data.quiz_question_option;

ROLLBACK;
