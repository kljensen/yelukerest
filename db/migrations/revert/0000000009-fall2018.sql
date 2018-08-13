START TRANSACTION;

SET search_path = public, pg_catalog;

CREATE TYPE _time_trial_type AS (
	a_time numeric
);

SET search_path = api, pg_catalog;

DROP FUNCTION save_quiz(quiz_id integer, quiz_question_option_ids integer[]);

DROP VIEW assignments;

DROP VIEW quizzes;

DROP VIEW quiz_submissions_info;

CREATE VIEW assignments AS
	SELECT assignment.slug,
    assignment.points_possible,
    assignment.is_draft,
    assignment.is_markdown,
    assignment.is_team,
    assignment.title,
    assignment.body,
    assignment.closed_at,
    assignment.created_at,
    assignment.updated_at,
    ((assignment.is_draft = false) AND (now() < assignment.closed_at)) AS is_open
   FROM data.assignment;
REVOKE ALL ON TABLE assignments FROM student;
GRANT SELECT ON TABLE assignments TO student;
REVOKE ALL ON TABLE assignments FROM faculty;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE assignments TO faculty;

CREATE VIEW quizzes AS
	SELECT quiz.id,
    quiz.meeting_id,
    quiz.points_possible,
    quiz.is_draft,
    quiz.duration,
    quiz.open_at,
    quiz.closed_at,
    quiz.created_at,
    quiz.updated_at,
    ((quiz.is_draft = false) AND (quiz.open_at < now()) AND (now() < quiz.closed_at)) AS is_open
   FROM data.quiz;
REVOKE ALL ON TABLE quizzes FROM student;
GRANT SELECT ON TABLE quizzes TO student;
REVOKE ALL ON TABLE quizzes FROM faculty;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE quizzes TO faculty;

SET search_path = data, pg_catalog;

DROP TRIGGER tg_assignment_field_submission_update_default ON assignment_field_submission;

DROP FUNCTION fill_assignment_field_submission_update_defaults();

ALTER TABLE assignment_field
	DROP CONSTRAINT assignment_field_assignment_slug_fkey;

ALTER TABLE assignment_submission
	DROP CONSTRAINT assignment_submission_assignment_slug_fkey;

ALTER TABLE engagement
	DROP CONSTRAINT engagement_meeting_id_fkey;

ALTER TABLE engagement
	DROP CONSTRAINT engagement_user_id_fkey;

ALTER TABLE quiz_question_option
	DROP CONSTRAINT quiz_question_option_quiz_question_id_fkey;

ALTER TABLE quiz_question_option
	DROP CONSTRAINT quiz_question_option_quiz_question_id_fkey1;

ALTER TABLE quiz_question
	DROP CONSTRAINT quiz_question_quiz_id_fkey;

ALTER TABLE assignment_field_submission
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE assignment_field
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE assignment_grade
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE assignment_submission
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE assignment
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE engagement
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE meeting
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE quiz_answer
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE quiz_grade
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE quiz_question_option
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE quiz_question
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE quiz_submission
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE quiz
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE team
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE ui_element
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

ALTER TABLE "user"
	ALTER COLUMN created_at SET DEFAULT now(),
	ALTER COLUMN updated_at SET DEFAULT now();

CREATE OR REPLACE FUNCTION fill_assignment_field_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT assignment_slug INTO NEW.assignment_slug
        FROM api.assignment_fields
        WHERE id = NEW.assignment_field_id;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;

ALTER TABLE assignment_field
	ADD CONSTRAINT assignment_field_assignment_slug_fkey FOREIGN KEY (assignment_slug) REFERENCES data.assignment(slug);

ALTER TABLE assignment_submission
	ADD CONSTRAINT assignment_submission_assignment_slug_fkey FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment(slug, is_team);

ALTER TABLE engagement
	ADD CONSTRAINT engagement_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES data.meeting(id) ON DELETE CASCADE;

ALTER TABLE engagement
	ADD CONSTRAINT engagement_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON DELETE CASCADE;

ALTER TABLE quiz_question_option
	ADD CONSTRAINT quiz_question_option_quiz_question_id_fkey FOREIGN KEY (quiz_question_id, quiz_id) REFERENCES data.quiz_question(id, quiz_id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE quiz_question
	ADD CONSTRAINT quiz_question_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON DELETE CASCADE;
ALTER POLICY quiz_answer_access_policy ON quiz_answer TO api
USING (
  (((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))
)
WITH CHECK (
  ((request.user_role() = 'faculty'::text) OR ((request.user_role() = 'student'::text) AND (request.user_id() = user_id) AND (EXISTS ( SELECT q.id,
    q.meeting_id,
    q.points_possible,
    q.is_draft,
    q.duration,
    q.open_at,
    q.closed_at,
    q.created_at,
    q.updated_at,
    q.is_open,
    qs.quiz_id,
    qs.user_id,
    qs.created_at,
    qs.updated_at
   FROM (api.quizzes q
     JOIN api.quiz_submissions qs ON ((q.id = qs.quiz_id)))
  WHERE ((q.id = qs.quiz_id) AND q.is_open AND ((qs.created_at + q.duration) > now()) AND (qs.user_id = qs.user_id))))))
);
ALTER POLICY user_access_policy ON "user" TO api
USING (
  (((request.user_role() = 'student'::text) AND (request.user_id() = id)) OR ((request.user_role() = 'faculty'::text) OR ("current_user"() = 'authapp'::name)))
);

COMMIT TRANSACTION;
