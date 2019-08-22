-- Deploy yelukerest:quiz_slugs to pg
-- requires: data

BEGIN;
ALTER TABLE data.quiz_question ADD COLUMN slug TEXT NOT NULL
    CHECK (slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$' AND char_length(slug) < 100);
ALTER TABLE data.quiz_question_option ADD COLUMN slug TEXT NOT NULL
    CHECK (slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$' AND char_length(slug) < 100);
CREATE UNIQUE INDEX quiz_question_quiz_id_slug_key ON data.quiz_question (quiz_id, slug);
CREATE UNIQUE INDEX quiz_question_option_quiz_question_id_slug_key ON data.quiz_question_option (quiz_question_id, slug);
COMMIT;
