START TRANSACTION;

SET search_path = data, pg_catalog;

ALTER TABLE quiz
	ADD CONSTRAINT quiz_id_points_possible_key UNIQUE (id, points_possible);


CREATE TABLE quiz_grade (
	quiz_id integer NOT NULL,
	points real NOT NULL,
	points_possible smallint NOT NULL,
	user_id integer NOT NULL,
	created_at timestamp with time zone DEFAULT now() NOT NULL,
	updated_at timestamp with time zone DEFAULT now() NOT NULL
);

REVOKE ALL ON TABLE quiz_grade FROM api;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE quiz_grade TO api;
ALTER TABLE quiz_grade  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION fill_quiz_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;

CREATE TRIGGER tg_quiz_grade_default
	BEFORE INSERT OR UPDATE ON quiz_grade
	FOR EACH ROW
	EXECUTE PROCEDURE fill_quiz_grade_defaults();

ALTER TABLE quiz_grade
	ADD CONSTRAINT quiz_grade_pkey PRIMARY KEY (quiz_id, user_id);

ALTER TABLE quiz_grade
	ADD CONSTRAINT points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision)));

ALTER TABLE quiz_grade
	ADD CONSTRAINT updated_after_created CHECK ((updated_at >= created_at));

ALTER TABLE quiz_grade
	ADD CONSTRAINT quiz_grade_quiz_id_fkey FOREIGN KEY (quiz_id, points_possible) REFERENCES quiz(id, points_possible) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE quiz_grade
	ADD CONSTRAINT quiz_grade_quiz_id_fkey1 FOREIGN KEY (quiz_id, user_id) REFERENCES quiz_submission(quiz_id, user_id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE quiz_grade
	ADD CONSTRAINT quiz_grade_user_id_fkey FOREIGN KEY (user_id) REFERENCES "user"(id) ON UPDATE CASCADE ON DELETE CASCADE;



SET search_path = api, pg_catalog;

CREATE VIEW quiz_grades AS
	SELECT quiz_grade.quiz_id,
    quiz_grade.points,
    quiz_grade.points_possible,
    quiz_grade.user_id,
    quiz_grade.created_at,
    quiz_grade.updated_at
   FROM data.quiz_grade;

ALTER VIEW quiz_grades OWNER TO api;
REVOKE ALL ON TABLE quiz_grades FROM student;
GRANT SELECT ON TABLE quiz_grades TO student;
REVOKE ALL ON TABLE quiz_grades FROM faculty;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE quiz_grades TO faculty;


CREATE POLICY quiz_grade_access_policy ON data.quiz_grade FOR ALL TO api
USING (
  (((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))
)
WITH CHECK (
  (request.user_role() = 'faculty'::text)
);

COMMIT TRANSACTION;
