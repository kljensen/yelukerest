START TRANSACTION;

SET search_path = data, pg_catalog;
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
    q.is_open
   FROM api.quizzes q
  WHERE ((q.id = quiz_answer.quiz_id) AND q.is_open)))))
);

COMMIT TRANSACTION;
