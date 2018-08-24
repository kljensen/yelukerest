START TRANSACTION;

SET search_path = api, pg_catalog;

DROP VIEW users;

CREATE VIEW users AS
	SELECT "user".id,
    "user".email,
    "user".netid,
    "user".name,
    "user".known_as,
    "user".nickname,
    "user".role,
    "user".created_at,
    "user".updated_at,
    "user".team_nickname
   FROM data."user";
REVOKE ALL ON TABLE users FROM student;
GRANT SELECT ON TABLE users TO student;
REVOKE ALL ON TABLE users FROM authapp;
GRANT SELECT ON TABLE users TO authapp;
REVOKE ALL ON TABLE users FROM faculty;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE users TO faculty;
REVOKE ALL ON TABLE users FROM ta;
GRANT SELECT ON TABLE users TO ta;

SET search_path = data, pg_catalog;

ALTER TABLE "user"
	DROP COLUMN lastname,
	DROP COLUMN organization;
ALTER POLICY assignment_field_submission_access_policy ON assignment_field_submission TO api
USING (
  (((request.user_role() = ANY ('{student,ta}'::text[])) AND ((submitter_user_id = request.user_id()) OR (EXISTS ( SELECT ass_sub.id,
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
  ((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND ((submitter_user_id = request.user_id()) AND (EXISTS ( SELECT ass_sub.id,
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
ALTER POLICY assignment_submission_access_policy ON assignment_submission TO api
USING (
  (((request.user_role() = ANY ('{student,ta}'::text[])) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id,
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
  ((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND (EXISTS ( SELECT a.slug,
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

COMMIT TRANSACTION;
