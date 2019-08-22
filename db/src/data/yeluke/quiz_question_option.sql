CREATE TABLE IF NOT EXISTS quiz_question_option (
    id SERIAL PRIMARY KEY,
    quiz_question_id INT REFERENCES quiz_question(id)
        ON UPDATE CASCADE ON DELETE CASCADE NOT NULL,
    slug TEXT NOT NULL
        CHECK (slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$' AND char_length(slug) < 100),
    -- Note that we're going to carry around the quiz_id
    -- so that we can ensure referential integrity. See the
    -- quiz_answer model for an explaination. 
    quiz_id INT NOT NULL,
    UNIQUE (id, quiz_id), -- used for a composite foreign key
    body text NOT NULL,
    is_markdown BOOLEAN DEFAULT false NOT NULL,
    is_correct BOOLEAN DEFAULT false NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    FOREIGN KEY (quiz_question_id, quiz_id) REFERENCES quiz_question(id, quiz_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    UNIQUE(quiz_question_id, slug)
);

DROP TRIGGER IF EXISTS tg_quiz_question_option_default ON quiz_question_option;
CREATE TRIGGER tg_quiz_question_option_default
    BEFORE INSERT OR UPDATE
    ON quiz_question_option
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();