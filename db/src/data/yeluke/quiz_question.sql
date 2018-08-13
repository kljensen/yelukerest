
CREATE TABLE IF NOT EXISTS quiz_question (
    id SERIAL PRIMARY KEY,
    quiz_id INT REFERENCES quiz(id)
        ON DELETE CASCADE ON UPDATE CASCADE NOT NULL,
    is_markdown BOOLEAN DEFAULT false,
    body text NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    UNIQUE (id, quiz_id)
    -- UNIQUE (id, quiz_id),
);


DROP TRIGGER IF EXISTS tg_quiz_question_default ON quiz_question;
CREATE TRIGGER tg_quiz_question_default
    BEFORE INSERT OR UPDATE
    ON quiz_question
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();