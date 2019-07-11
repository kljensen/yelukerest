
CREATE TABLE IF NOT EXISTS quiz_grade_exception (
    -- Assignment: team, not team
    -- Quiz
    meeting_slug VARCHAR(100) REFERENCES meeting(slug)
        ON DELETE CASCADE
        ON UPDATE CASCADE
        NOT NULL,
    user_id INT REFERENCES "user"(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
        NOT NULL,
    closed_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    PRIMARY KEY (meeting_slug, user_id)
);


DROP TRIGGER IF EXISTS tg_quiz_grade_exception_default ON quiz_grade_exception;
CREATE TRIGGER tg_quiz_grade_exception_default
    BEFORE INSERT OR UPDATE
    ON quiz_grade_exception
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();