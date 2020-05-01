CREATE TABLE IF NOT EXISTS quiz_answer (
    -- Note, we are going to cascade foreign key updates
    -- through composite foreign keys, not the individual columns.
    quiz_id INT NOT NULL,
    user_id INT NOT NULL,
    quiz_question_option_id INT NOT NULL,
    -- A user can only select an option once per quiz submission
    PRIMARY KEY (quiz_id, user_id, quiz_question_option_id),
    -- This quiz answer must point to a quiz submission
    FOREIGN KEY (quiz_id, user_id)
        REFERENCES quiz_submission(quiz_id, user_id)
        ON UPDATE CASCADE,
    -- This quiz answer must point to a quiz question option
    FOREIGN KEY (quiz_question_option_id, quiz_id)
        REFERENCES quiz_question_option(id, quiz_id)
        ON UPDATE CASCADE,

    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at)
);

CREATE OR REPLACE FUNCTION fill_answer_defaults()
RETURNS TRIGGER AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.quiz_id IS NULL) THEN
        SELECT quiz_id INTO NEW.quiz_id
        FROM api.quiz_question_options
        WHERE id = NEW.quiz_question_option_id;
    END IF;
    IF (NEW.user_id IS NULL and request.user_id() IS NOT NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';


DROP TRIGGER IF EXISTS tg_quiz_answer_default ON quiz_answer;
CREATE TRIGGER tg_quiz_answer_default
    BEFORE INSERT OR UPDATE
    ON quiz_answer
    FOR EACH ROW
EXECUTE PROCEDURE fill_answer_defaults();
