-- Grading exceptions help us keep track of the following:
-- * Extended due dates for particular students or teams; and,
-- * Grade adjustments, either on a percentage or fixed points basis
-- That is true for either assignments or quizzes.
CREATE TABLE IF NOT EXISTS grade_exception (
    -- We use a artificial (surrogate) primary key so
    -- that we have an easy way to refer to each row.
    -- We cannot do something like
    -- PRIMARY KEY(quiz_id, assignment_slug, user_id, team_nickname),
    -- because some of those columns could be NULL and
    -- none are allowed to be NULL in a primary key.
    id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quiz_id INT REFERENCES quiz(id)
        ON UPDATE CASCADE
        ON DELETE CASCADE,
    user_id INT REFERENCES "user"(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    assignment_slug VARCHAR(100),
    is_team BOOLEAN,
    FOREIGN KEY (assignment_slug, is_team)
        REFERENCES assignment(slug, is_team)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    team_nickname VARCHAR(50)
    REFERENCES team(nickname)
        ON DELETE CASCADE
        ON UPDATE CASCADE,
    CONSTRAINT matches_quiz_or_assignment CHECK (
        (
          -- This grading exception refers to a quiz
          quiz_id IS NOT NULL AND
          user_id IS NOT NULL AND
          assignment_slug IS NULL AND
          is_team IS NULL AND
          team_nickname IS NULL
        ) OR (
          -- This grading exception refers to an assignment
          quiz_id IS NULL AND
          assignment_slug IS NOT NULL AND
          (
            (is_team=TRUE AND (team_nickname IS NOT NULL) AND (user_id IS NULL))
            OR
            (is_team=FALSE AND (team_nickname IS NULL) AND (user_id IS NOT NULL))
          )
        )
    ),

    -- This can be used to extend deadline for
    -- an assignment or quiz.
    closed_at TIMESTAMP WITH TIME ZONE,
    fractional_credit DECIMAL DEFAULT 1
        CHECK (fractional_credit >= 0 AND fractional_credit <= 1),

    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at)
);