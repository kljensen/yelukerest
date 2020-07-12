
CREATE TABLE IF NOT EXISTS quiz_grade (
    quiz_id INT NOT NULL,
    points REAL NOT NULL,
    points_possible smallint NOT NULL,
    description TEXT,
    user_id INT REFERENCES "user"(id)
        ON UPDATE CASCADE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT points_in_range CHECK (points >= 0 AND points <= points_possible),
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    -- Must point to quiz
    FOREIGN KEY (quiz_id, points_possible)
        REFERENCES quiz(id, points_possible)
        ON UPDATE CASCADE,
    -- Must point to a quiz submission
    FOREIGN KEY (quiz_id, user_id)
        REFERENCES quiz_submission(quiz_id, user_id)
        ON UPDATE CASCADE,
    PRIMARY KEY (quiz_id, user_id)
);

CREATE OR REPLACE FUNCTION fill_quiz_grade_defaults()
RETURNS TRIGGER AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM api.quizzes
        WHERE id = NEW.quiz_id;
    END IF;
    IF (NEW.user_id IS NULL and request.user_id() IS NOT NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';


DROP TRIGGER IF EXISTS tg_quiz_grade_default ON quiz_grade;
CREATE TRIGGER tg_quiz_grade_default
    BEFORE INSERT OR UPDATE
    ON quiz_grade
    FOR EACH ROW
EXECUTE PROCEDURE fill_quiz_grade_defaults();
