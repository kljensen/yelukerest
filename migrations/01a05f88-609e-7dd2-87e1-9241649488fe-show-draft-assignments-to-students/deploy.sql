-- Let students see draft assignments, labelled, instead of hiding them.
--
-- `is_draft` on an assignment meant two things at once: this is not finished,
-- and this is a secret. Only the first was ever intended. A draft meeting is
-- visible to students with a marker on it -- api.meetings is an unfiltered
-- SELECT * and the client renders the flag -- and an assignment should behave
-- the same way. A syllabus that hides what is coming is not much of a syllabus:
-- the four project sprints, sixty points between them and due from November,
-- were invisible, so nobody could see the project even had four sprints.
--
-- The client was already built for this and the code is currently unreachable.
-- Assignments/Model.elm has an explicit `NotSubmissible IsDraft` state, and
-- Views.elm calls showDraftStatus on both the list and the detail page. No
-- client change accompanies this migration; those paths simply start running.
--
-- Nothing depended on the invisibility for correctness. Three independent
-- guards already stop a student submitting to a draft, and none of them is
-- touched here:
--
--   * is_open is computed as (is_draft = false AND now < closed_at), so it is
--     false for every draft;
--   * the client refuses before it asks, via isSubmissible;
--   * the row-level security policy on data.assignment_submission requires
--     a.is_draft = False, so the database refuses whatever the client does.
--
-- api.assignment_grade_distribution excludes drafts on its own, so grades and
-- distributions are unaffected.
--
-- The consequence to be deliberate about: `is_draft` is no longer a
-- scratchpad. Anything marked draft is public the moment it exists, so an
-- unfinished assignment should say so in its body -- as the sprints do.
--
-- Both definitions below are the deployed ones with the WHERE clause removed;
-- the column lists are reproduced exactly, since CREATE OR REPLACE VIEW
-- requires the same columns in the same order.

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
   FROM data.assignment;

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
   FROM data.assignment_field field;

ALTER VIEW api.assignment_fields OWNER TO api;

-- CREATE OR REPLACE VIEW keeps existing privileges, but restating them costs
-- nothing and means this migration is a complete description of the end state.
GRANT SELECT ON api.assignments TO student, ta;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.assignments TO faculty;
GRANT SELECT ON api.assignment_fields TO student, ta;
GRANT SELECT, INSERT, UPDATE, DELETE ON api.assignment_fields TO faculty;

-- Close the exception branch of the field-write guard while we are here.
--
-- Making drafts readable is only safe because writing to one is refused, and
-- that refusal was not quite complete. data.assignment_submission's policy
-- names a.is_draft = False in BOTH its ordinary and its grade-exception
-- branches, but this helper -- which governs assignment_field_submission
-- writes -- named it only in the ordinary one. So a student holding a live
-- exception could still write field submissions to a draft, provided a parent
-- submission already existed for it (faculty can create one, and an assignment
-- published, submitted to, and later marked draft leaves one behind).
--
-- That predates this migration and visibility does not cause it. But shipping
-- a change that invites students to look at drafts, while leaving a way to
-- write to one, is the wrong order to do things in. The exception branch now
-- carries the same condition as the ordinary branch, which is what
-- assignment_submission already does.

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
                    a.is_draft = false
                    AND ge.closed_at > current_timestamp
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

-- PostgREST caches the schema; without this it keeps serving the old views.
NOTIFY pgrst, 'reload schema';
