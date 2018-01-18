
CREATE TABLE IF NOT EXISTS quiz_submission (
    quiz_id INT REFERENCES quiz(id)
        ON UPDATE CASCADE
        ON DELETE CASCADE
        NOT NULL,
    user_id INT REFERENCES "user"(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
        NOT NULL DEFAULT request.user_id(),
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    PRIMARY KEY (quiz_id, user_id)
    -- UNIQUE (id, quiz_id),
);


CREATE OR REPLACE FUNCTION fill_quiz_submission_defaults()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.user_id IS NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';

DROP TRIGGER IF EXISTS tg_quiz_submission_default ON quiz_submission;
CREATE TRIGGER tg_quiz_submission_default
    BEFORE INSERT OR UPDATE
    ON quiz_submission
    FOR EACH ROW
EXECUTE PROCEDURE fill_quiz_submission_defaults();