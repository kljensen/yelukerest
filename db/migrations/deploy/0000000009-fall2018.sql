START TRANSACTION;

SET search_path = public, pg_catalog;

DROP TYPE _time_trial_type;

SET search_path = api, pg_catalog;

DROP VIEW assignments;

DROP VIEW quizzes;

CREATE OR REPLACE FUNCTION save_quiz(quiz_id integer, quiz_question_option_ids integer[]) RETURNS SETOF data.quiz_answer
    LANGUAGE plpgsql
    AS $_$
BEGIN
    -- Functions are executed in a transaction.
    -- Delete all quiz_answers for this user's quiz_submission for this quiz_id.
    DELETE FROM api.quiz_answers qa WHERE qa.quiz_id = $1 AND qa.user_id = request.user_id();
    -- Insert the submitted quiz answers.
    INSERT INTO api.quiz_answers(quiz_question_option_id, user_id, quiz_id) select unnest($2), request.user_id(), $1;
    -- Return all quiz answers for this quiz_id.
    RETURN QUERY
        SELECT * FROM api.quiz_answers qa WHERE qa.quiz_id = $1;
END; $_$;

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
    ((assignment.is_draft = false) AND (CURRENT_TIMESTAMP < assignment.closed_at)) AS is_open
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
    ((quiz.is_draft = false) AND (quiz.open_at < CURRENT_TIMESTAMP) AND (CURRENT_TIMESTAMP < quiz.closed_at)) AS is_open
   FROM data.quiz;
REVOKE ALL ON TABLE quizzes FROM student;
GRANT SELECT ON TABLE quizzes TO student;
REVOKE ALL ON TABLE quizzes FROM faculty;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE quizzes TO faculty;

CREATE VIEW quiz_submissions_info AS
	SELECT qs.quiz_id,
    qs.user_id,
    qs.created_at,
    qs.updated_at,
    (q.is_open AND (CURRENT_TIMESTAMP < LEAST(q.closed_at, (qs.created_at + q.duration)))) AS is_open,
    LEAST(q.closed_at, (qs.created_at + q.duration)) AS closed_at
   FROM (api.quiz_submissions qs
     JOIN api.quizzes q ON ((qs.quiz_id = q.id)));

ALTER VIEW quiz_submissions_info OWNER TO api;
REVOKE ALL ON TABLE quiz_submissions_info FROM student;
GRANT SELECT ON TABLE quiz_submissions_info TO student;
REVOKE ALL ON TABLE quiz_submissions_info FROM faculty;
GRANT SELECT ON TABLE quiz_submissions_info TO faculty;

SET search_path = data, pg_catalog;

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

ALTER TABLE quiz_question
	DROP CONSTRAINT quiz_question_quiz_id_fkey;

ALTER SEQUENCE assignment_field_id_seq
	AS integer;

ALTER SEQUENCE assignment_submission_id_seq
	AS integer;

ALTER SEQUENCE meeting_id_seq
	AS integer;

ALTER SEQUENCE quiz_id_seq
	AS integer;

ALTER SEQUENCE quiz_question_id_seq
	AS integer;

ALTER SEQUENCE quiz_question_option_id_seq
	AS integer;

ALTER SEQUENCE todo_id_seq
	AS integer;

ALTER SEQUENCE user_id_seq
	AS integer;

ALTER TABLE quiz_answer
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE assignment_field_submission
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE assignment_field
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE assignment_grade
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE assignment_submission
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE assignment
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE engagement
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE meeting
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE quiz_grade
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE quiz_question_option
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE quiz_question
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE quiz_submission
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE quiz
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE team
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE ui_element
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE "user"
	ALTER COLUMN created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN updated_at SET DEFAULT CURRENT_TIMESTAMP;

CREATE OR REPLACE FUNCTION fill_assignment_field_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Fill in the assignment_slug if it is null
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT assignment_slug INTO NEW.assignment_slug
        FROM api.assignment_fields
        WHERE id = NEW.assignment_field_id;
    END IF;
    -- Fill in the assignment_submission_id if it is null.
    IF (NEW.assignment_submission_id IS NULL and NEW.assignment_slug IS NOT NULL and request.user_id() IS NOT NULL) THEN
        SELECT ass.id INTO NEW.assignment_submission_id
        FROM
            (api.assignment_submissions ass
            LEFT OUTER JOIN api.users u
            ON u.team_nickname = ass.team_nickname)
        WHERE (
            -- It is the right assignment
            assignment_slug = NEW.assignment_slug
            AND
            -- It is theirs or their teams assignment submission
            (u.id = request.user_id() OR user_id = request.user_id())
        );
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fill_assignment_field_submission_update_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- TODO: Should I only do this for people in
    -- the 'student' role, or != 'faculty' role?
    IF (request.user_id() IS NOT NULL) THEN
        NEW.submitter_user_id = request.user_id();
    END IF;
    RETURN NEW;
END;
$$;

ALTER TABLE assignment_field
	ADD CONSTRAINT assignment_field_assignment_slug_fkey FOREIGN KEY (assignment_slug) REFERENCES data.assignment(slug) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE assignment_submission
	ADD CONSTRAINT assignment_submission_assignment_slug_fkey FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment(slug, is_team) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE engagement
	ADD CONSTRAINT engagement_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES data.meeting(id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE engagement
	ADD CONSTRAINT engagement_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE quiz_question_option
	ADD CONSTRAINT quiz_question_option_quiz_question_id_fkey FOREIGN KEY (quiz_question_id) REFERENCES data.quiz_question(id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE quiz_question_option
	ADD CONSTRAINT quiz_question_option_quiz_question_id_fkey1 FOREIGN KEY (quiz_question_id, quiz_id) REFERENCES data.quiz_question(id, quiz_id) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE quiz_question
	ADD CONSTRAINT quiz_question_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE ON DELETE CASCADE;

CREATE TRIGGER tg_assignment_field_submission_update_default
	BEFORE INSERT OR UPDATE ON assignment_field_submission
	FOR EACH ROW
	EXECUTE PROCEDURE data.fill_assignment_field_submission_update_defaults();
ALTER POLICY quiz_answer_access_policy ON quiz_answer TO api
USING (
  (((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))
)
WITH CHECK (
  ((request.user_role() = 'faculty'::text) OR ((request.user_role() = 'student'::text) AND (request.user_id() = user_id) AND (EXISTS ( SELECT qsi.quiz_id,
    qsi.user_id,
    qsi.created_at,
    qsi.updated_at,
    qsi.is_open,
    qsi.closed_at
   FROM api.quiz_submissions_info qsi
  WHERE ((qsi.quiz_id = qsi.quiz_id) AND qsi.is_open AND (qsi.user_id = qsi.user_id))))))
);
ALTER POLICY user_access_policy ON "user" TO api
USING (
  (((request.user_role() = 'student'::text) AND (request.user_id() = id)) OR ((request.user_role() = 'faculty'::text) OR (CURRENT_USER = 'authapp'::name)))
);

COMMIT TRANSACTION;
