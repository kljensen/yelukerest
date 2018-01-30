START TRANSACTION;


SET search_path = data, pg_catalog;

CREATE TABLE assignment_grade (
	assignment_slug character varying(100) NOT NULL,
	points_possible smallint NOT NULL,
	assignment_submission_id integer NOT NULL,
	points real NOT NULL,
	created_at timestamp with time zone DEFAULT now() NOT NULL,
	updated_at timestamp with time zone DEFAULT now() NOT NULL
);

REVOKE ALL ON TABLE assignment_grade FROM api;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE assignment_grade TO api;
ALTER TABLE assignment_grade  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION fill_assignment_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT ass_sub.assignment_slug INTO NEW.assignment_slug
        FROM api.assignment_submissions as ass_sub
        WHERE ass_sub.id = NEW.assignment_submission_id;
    END IF;
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM api.assignments
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;

ALTER TABLE assignment
	ADD CONSTRAINT assignment_slug_points_possible_key UNIQUE (slug, points_possible);

ALTER TABLE assignment_grade
	ADD CONSTRAINT assignment_grade_pkey PRIMARY KEY (assignment_submission_id);

ALTER TABLE assignment_grade
	ADD CONSTRAINT points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision)));

ALTER TABLE assignment_grade
	ADD CONSTRAINT updated_after_created CHECK ((updated_at >= created_at));

ALTER TABLE assignment_grade
	ADD CONSTRAINT assignment_grade_assignment_slug_fkey FOREIGN KEY (assignment_slug, points_possible) REFERENCES assignment(slug, points_possible) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE assignment_grade
	ADD CONSTRAINT assignment_grade_assignment_submission_id_fkey FOREIGN KEY (assignment_submission_id, assignment_slug) REFERENCES assignment_submission(id, assignment_slug) ON UPDATE CASCADE ON DELETE CASCADE;


CREATE TRIGGER tg_assignment_grade_default
	BEFORE INSERT OR UPDATE ON assignment_grade
	FOR EACH ROW
	EXECUTE PROCEDURE fill_assignment_grade_defaults();


CREATE POLICY assignment_grade_access_policy ON assignment_grade FOR ALL TO api
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

-- ------------------------ SET UP THE API

SET search_path = api, pg_catalog;

CREATE VIEW assignment_grades AS
	SELECT assignment_grade.assignment_slug,
    assignment_grade.points_possible,
    assignment_grade.assignment_submission_id,
    assignment_grade.points,
    assignment_grade.created_at,
    assignment_grade.updated_at
   FROM data.assignment_grade;

ALTER VIEW assignment_grades OWNER TO api;
REVOKE ALL ON TABLE assignment_grades FROM student;
GRANT SELECT ON TABLE assignment_grades TO student;
REVOKE ALL ON TABLE assignment_grades FROM faculty;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE assignment_grades TO faculty;


COMMIT TRANSACTION;
