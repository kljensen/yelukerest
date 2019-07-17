
CREATE TABLE IF NOT EXISTS quiz_grade_exception (
    id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quiz_id INT REFERENCES quiz(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
        NOT NULL,
    user_id INT REFERENCES "user"(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE
        NOT NULL,
    fractional_credit DECIMAL NOT NULL DEFAULT 1
        CHECK (fractional_credit >= 0 AND fractional_credit <= 1),
    closed_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    UNIQUE (quiz_id, user_id)
);


DROP TRIGGER IF EXISTS tg_quiz_grade_exception_default ON quiz_grade_exception;
CREATE TRIGGER tg_quiz_grade_exception_default
    BEFORE INSERT OR UPDATE
    ON quiz_grade_exception
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();