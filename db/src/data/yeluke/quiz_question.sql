
CREATE TABLE IF NOT EXISTS quiz_question (
    slug TEXT NOT NULL
        CHECK (slug ~ '^[a-z0-9-]+$' AND char_length(slug) < 60),
    meeting_slug TEXT REFERENCES quiz(meeting_slug)
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
    PRIMARY KEY (slug, meeting_slug)
);


DROP TRIGGER IF EXISTS tg_quiz_question_default ON quiz_question;
CREATE TRIGGER tg_quiz_question_default
    BEFORE INSERT OR UPDATE
    ON quiz_question
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();