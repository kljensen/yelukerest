-- Restore the draft filter on both views, exactly as deployed before.
CREATE OR REPLACE VIEW api.assignments WITH (security_barrier='true') AS
 SELECT slug,
    points_possible,
    is_draft,
    is_markdown,
    is_team,
    title,
    body,
    closed_at,
    created_at,
    updated_at,
    ((is_draft = false) AND (CURRENT_TIMESTAMP < closed_at)) AS is_open
   FROM data.assignment
  WHERE ((request.user_role() = 'faculty'::text) OR (is_draft = false));

ALTER VIEW api.assignments OWNER TO api;

CREATE OR REPLACE VIEW api.assignment_fields WITH (security_barrier='true') AS
 SELECT slug,
    assignment_slug,
    label,
    help,
    placeholder,
    is_url,
    is_multiline,
    display_order,
    pattern,
    example,
    created_at,
    updated_at
   FROM data.assignment_field field
  WHERE ((request.user_role() = 'faculty'::text) OR (EXISTS ( SELECT 1
           FROM data.assignment assignment
          WHERE ((assignment.slug = field.assignment_slug) AND (assignment.is_draft = false)))));

ALTER VIEW api.assignment_fields OWNER TO api;

GRANT SELECT ON api.assignments TO student, ta;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.assignments TO faculty;
GRANT SELECT ON api.assignment_fields TO student, ta;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.assignment_fields TO faculty;

-- Restore the helper's exception branch as it was.
CREATE OR REPLACE FUNCTION data.assignment_field_submission_is_writable_by_current_user(the_assignment_submission_id integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $function$
BEGIN
    RETURN EXISTS (
        SELECT ass_sub.id
        FROM data.assignment_submission AS ass_sub
        INNER JOIN data."user" AS u
        ON (
            ass_sub.user_id = u.id
            OR
            ass_sub.team_nickname = u.team_nickname
        )
        INNER JOIN data.assignment AS a
        ON a.slug = ass_sub.assignment_slug
        LEFT JOIN data.assignment_grade_exception AS ge
        ON (
            ge.assignment_slug = ass_sub.assignment_slug
            AND
            (
                (ass_sub.is_team AND ge.team_nickname = ass_sub.team_nickname)
                OR
                (NOT ass_sub.is_team AND ge.user_id = ass_sub.user_id)
            )
        )
        WHERE
            u.id = request.user_id()
            AND ass_sub.id = the_assignment_submission_id
            AND (
                (
                    a.is_draft = false
                    AND current_timestamp < a.closed_at
                )
                OR
                (
                    ge.closed_at > current_timestamp
                    AND (
                        ge.user_id = ass_sub.user_id
                        OR
                        ge.team_nickname = ass_sub.team_nickname
                    )
                )
            )
    );
END;
$function$;

NOTIFY pgrst, 'reload schema';
