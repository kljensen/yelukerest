
CREATE TABLE IF NOT EXISTS quiz_grade (
    quiz_id INT NOT NULL,
    points smallint NOT NULL,
    points_possible smallint NOT NULL,
    user_id INT REFERENCES "user"(id)
        ON DELETE CASCADE ON UPDATE CASCADE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT points_in_range CHECK (points <= points_possible),
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    -- Must point to quiz
    FOREIGN KEY (quiz_id, points_possible)
        REFERENCES quiz(id, points_possible)
        ON UPDATE CASCADE ON DELETE CASCADE,
    -- Must point to a quiz submission
    FOREIGN KEY (quiz_id, user_id)
        REFERENCES quiz_submission(quiz_id, user_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    PRIMARY KEY (quiz_id, user_id)
);
