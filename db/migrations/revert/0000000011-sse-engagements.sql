START TRANSACTION;

SET search_path = public, pg_catalog;

DROP TYPE _time_trial_type;

REVOKE ALL ON TABLE assignment_field_submissions FROM ta;

REVOKE ALL ON TABLE assignment_fields FROM ta;

REVOKE ALL ON TABLE assignment_grades FROM ta;

REVOKE ALL ON TABLE assignment_submissions FROM ta;

REVOKE ALL ON TABLE assignments FROM ta;

REVOKE ALL ON TABLE engagements FROM ta;

REVOKE ALL ON TABLE meetings FROM ta;

REVOKE ALL ON TABLE quiz_answers FROM ta;

REVOKE ALL ON TABLE quiz_grades FROM ta;

REVOKE ALL (id) ON TABLE quiz_question_options FROM ta;
REVOKE ALL (quiz_question_id) ON TABLE quiz_question_options FROM ta;
REVOKE ALL (quiz_id) ON TABLE quiz_question_options FROM ta;
REVOKE ALL (body) ON TABLE quiz_question_options FROM ta;
REVOKE ALL (is_markdown) ON TABLE quiz_question_options FROM ta;
REVOKE ALL (created_at) ON TABLE quiz_question_options FROM ta;
REVOKE ALL (updated_at) ON TABLE quiz_question_options FROM ta;

REVOKE ALL ON TABLE quiz_questions FROM ta;

REVOKE ALL ON TABLE quiz_submissions FROM ta;

REVOKE ALL ON TABLE quizzes FROM ta;

REVOKE ALL ON TABLE quiz_submissions_info FROM ta;

REVOKE ALL ON TABLE teams FROM ta;

REVOKE ALL ON TABLE ui_elements FROM ta;

REVOKE ALL ON TABLE users FROM ta;

SET search_path = data, pg_catalog;

DROP TRIGGER engagement_rabbitmq_tg ON engagement;

REVOKE ALL ON SEQUENCE assignment_submission_id_seq FROM ta;

REVOKE ALL ON SEQUENCE quiz_id_seq FROM student;
GRANT USAGE ON SEQUENCE quiz_id_seq TO student;

REVOKE ALL ON SEQUENCE quiz_question_id_seq FROM ta;

REVOKE ALL ON SEQUENCE quiz_question_option_id_seq FROM ta;
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
ALTER POLICY assignment_field_submission_access_policy ON assignment_field_submission TO api
USING (
  (((request.user_role() = 'student'::text) AND ((submitter_user_id = request.user_id()) OR (EXISTS ( SELECT ass_sub.id,
    ass_sub.assignment_slug,
    ass_sub.is_team,
    ass_sub.user_id,
    ass_sub.team_nickname,
    ass_sub.submitter_user_id,
    ass_sub.created_at,
    ass_sub.updated_at,
    users.id,
    users.email,
    users.netid,
    users.name,
    users.known_as,
    users.nickname,
    users.role,
    users.created_at,
    users.updated_at,
    users.team_nickname
   FROM (api.assignment_submissions ass_sub
     JOIN api.users ON (((ass_sub.user_id = users.id) OR ((ass_sub.team_nickname)::text = (users.team_nickname)::text))))
  WHERE ((users.id = request.user_id()) AND (ass_sub.id = assignment_field_submission.assignment_submission_id)))))) OR (request.user_role() = 'faculty'::text))
)
WITH CHECK (
  ((request.user_role() = 'faculty'::text) OR ((request.user_role() = 'student'::text) AND ((submitter_user_id = request.user_id()) AND (EXISTS ( SELECT ass_sub.id,
    ass_sub.assignment_slug,
    ass_sub.is_team,
    ass_sub.user_id,
    ass_sub.team_nickname,
    ass_sub.submitter_user_id,
    ass_sub.created_at,
    ass_sub.updated_at,
    users.id,
    users.email,
    users.netid,
    users.name,
    users.known_as,
    users.nickname,
    users.role,
    users.created_at,
    users.updated_at,
    users.team_nickname,
    assignments.slug,
    assignments.points_possible,
    assignments.is_draft,
    assignments.is_markdown,
    assignments.is_team,
    assignments.title,
    assignments.body,
    assignments.closed_at,
    assignments.created_at,
    assignments.updated_at,
    assignments.is_open
   FROM ((api.assignment_submissions ass_sub
     JOIN api.users ON (((ass_sub.user_id = users.id) OR ((ass_sub.team_nickname)::text = (users.team_nickname)::text))))
     JOIN api.assignments ON (((assignments.slug)::text = (ass_sub.assignment_slug)::text)))
  WHERE ((assignments.is_open = true) AND (users.id = request.user_id()) AND (ass_sub.id = assignment_field_submission.assignment_submission_id)))))))
);
ALTER POLICY assignment_grade_access_policy ON assignment_grade TO api
USING (
  (((request.user_role() = 'student'::text) AND (EXISTS ( SELECT ass_sub.id,
    ass_sub.assignment_slug,
    ass_sub.is_team,
    ass_sub.user_id,
    ass_sub.team_nickname,
    ass_sub.submitter_user_id,
    ass_sub.created_at,
    ass_sub.updated_at
   FROM api.assignment_submissions ass_sub
  WHERE (assignment_grade.assignment_submission_id = ass_sub.id)))) OR (request.user_role() = 'faculty'::text))
)
WITH CHECK (
  (request.user_role() = 'faculty'::text)
);
ALTER POLICY assignment_submission_access_policy ON assignment_submission TO api
USING (
  (((request.user_role() = 'student'::text) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id,
    u.email,
    u.netid,
    u.name,
    u.known_as,
    u.nickname,
    u.role,
    u.created_at,
    u.updated_at,
    u.team_nickname
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND ((u.team_nickname)::text = (assignment_submission.team_nickname)::text))))))) OR (request.user_role() = 'faculty'::text))
)
WITH CHECK (
  ((request.user_role() = 'faculty'::text) OR ((request.user_role() = 'student'::text) AND (EXISTS ( SELECT a.slug,
    a.points_possible,
    a.is_draft,
    a.is_markdown,
    a.is_team,
    a.title,
    a.body,
    a.closed_at,
    a.created_at,
    a.updated_at,
    a.is_open
   FROM api.assignments a
  WHERE (((a.slug)::text = (assignment_submission.assignment_slug)::text) AND a.is_open))) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id,
    u.email,
    u.netid,
    u.name,
    u.known_as,
    u.nickname,
    u.role,
    u.created_at,
    u.updated_at,
    u.team_nickname
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND ((u.team_nickname)::text = (assignment_submission.team_nickname)::text))))))))
);
ALTER POLICY engagement_access_policy ON engagement TO api
USING (
  (((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))
);
ALTER POLICY quiz_grade_access_policy ON quiz_grade TO api
USING (
  (((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))
)
WITH CHECK (
  (request.user_role() = 'faculty'::text)
);
ALTER POLICY quiz_question_option_access_policy ON quiz_question_option TO api
USING (
  (((request.user_role() = 'student'::text) AND (EXISTS ( SELECT qs.quiz_id,
    qs.user_id,
    qs.created_at,
    qs.updated_at
   FROM api.quiz_submissions qs
  WHERE ((qs.user_id = request.user_id()) AND (quiz_question_option.quiz_id = qs.quiz_id))))) OR (request.user_role() = 'faculty'::text))
);
ALTER POLICY quiz_question_access_policy ON quiz_question TO api
USING (
  (((request.user_role() = 'student'::text) AND (EXISTS ( SELECT qs.quiz_id,
    qs.user_id,
    qs.created_at,
    qs.updated_at
   FROM api.quiz_submissions qs
  WHERE ((qs.user_id = request.user_id()) AND (quiz_question.quiz_id = qs.quiz_id))))) OR (request.user_role() = 'faculty'::text))
);
ALTER POLICY quiz_submission_access_policy ON quiz_submission TO api
USING (
  (((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))
)
WITH CHECK (
  ((request.user_role() = 'faculty'::text) OR ((request.user_role() = 'student'::text) AND ((request.user_id() = user_id) AND (EXISTS ( SELECT q.id,
    q.meeting_id,
    q.points_possible,
    q.is_draft,
    q.duration,
    q.open_at,
    q.closed_at,
    q.created_at,
    q.updated_at,
    q.is_open
   FROM api.quizzes q
  WHERE ((q.id = quiz_submission.quiz_id) AND q.is_open))))))
);
ALTER POLICY team_access_policy ON team TO api
USING (
  (((request.user_role() = 'student'::text) AND ((nickname)::text = (( SELECT users.team_nickname
   FROM api.users
  WHERE (users.id = request.user_id())))::text)) OR (request.user_role() = 'faculty'::text))
);
ALTER POLICY user_access_policy ON "user" TO api
USING (
  (((request.user_role() = 'student'::text) AND (request.user_id() = id)) OR ((request.user_role() = 'faculty'::text) OR (CURRENT_USER = 'authapp'::name)))
);

COMMIT TRANSACTION;
