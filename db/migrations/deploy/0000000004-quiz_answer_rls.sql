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
    q.is_open,
    qs.quiz_id,
    qs.user_id,
    qs.created_at,
    qs.updated_at
   FROM (api.quizzes q
     JOIN api.quiz_submissions qs ON ((q.id = qs.quiz_id)))
  WHERE ((q.id = qs.quiz_id) AND q.is_open AND ((qs.created_at + q.duration) > now()) AND (qs.user_id = qs.user_id))))))
);

COMMIT TRANSACTION;
