
-- This file was created automatically by the create-initial-migrations.sh
-- script. DO NOT EDIT BY HAND.

BEGIN;

--
-- PostgreSQL database dump
--

-- Dumped from database version 18.4
-- Dumped by pg_dump version 18.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: api; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA api;


ALTER SCHEMA api OWNER TO superuser;

--
-- Name: auth; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA auth;


ALTER SCHEMA auth OWNER TO superuser;

--
-- Name: data; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA data;


ALTER SCHEMA data OWNER TO superuser;

--
-- Name: pgjwt; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA pgjwt;


ALTER SCHEMA pgjwt OWNER TO superuser;

--
-- Name: request; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA request;


ALTER SCHEMA request OWNER TO superuser;

--
-- Name: settings; Type: SCHEMA; Schema: -; Owner: superuser
--

CREATE SCHEMA settings;


ALTER SCHEMA settings OWNER TO superuser;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: user; Type: TYPE; Schema: api; Owner: superuser
--

CREATE TYPE api."user" AS (
	id integer,
	netid text,
	email text,
	role text
);


ALTER TYPE api."user" OWNER TO superuser;

--
-- Name: participation_enum; Type: TYPE; Schema: data; Owner: superuser
--

CREATE TYPE data.participation_enum AS ENUM (
    'absent',
    'attended',
    'contributed',
    'led'
);


ALTER TYPE data.participation_enum OWNER TO superuser;

--
-- Name: user_role; Type: TYPE; Schema: data; Owner: superuser
--

CREATE TYPE data.user_role AS ENUM (
    'student',
    'faculty',
    'observer',
    'ta'
);


ALTER TYPE data.user_role OWNER TO superuser;

--
-- Name: sync_assignments(jsonb, boolean, boolean); Type: FUNCTION; Schema: api; Owner: superuser
--

CREATE FUNCTION api.sync_assignments(p_assignments jsonb, p_delete_missing boolean DEFAULT false, p_dry_run boolean DEFAULT false) RETURNS TABLE(inserted_count integer, updated_count integer, unchanged_count integer, deleted_count integer, field_inserted_count integer, field_updated_count integer, field_unchanged_count integer, field_deleted_count integer, dry_run boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
    input_count integer;
    duplicate_assignment_slug text;
    invalid_assignment_field_slug text;
    duplicate_field_key text;
BEGIN
    p_delete_missing := COALESCE(p_delete_missing, false);
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;

    IF p_assignments IS NULL OR jsonb_typeof(p_assignments) <> 'array' THEN
        RAISE EXCEPTION 'sync_assignments expects a JSON array'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_assignments);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'sync_assignments refuses to sync an empty assignment list'
            USING ERRCODE = '22023';
    END IF;

    SELECT assignment.slug INTO duplicate_assignment_slug
    FROM jsonb_to_recordset(p_assignments) AS assignment (
        slug text
    )
    GROUP BY assignment.slug
    HAVING count(*) > 1
    LIMIT 1;

    IF duplicate_assignment_slug IS NOT NULL THEN
        RAISE EXCEPTION 'sync_assignments received duplicate assignment slug: %', duplicate_assignment_slug
            USING ERRCODE = '23505';
    END IF;

    SELECT COALESCE(assignment.value->>'slug', '<missing slug>') INTO invalid_assignment_field_slug
    FROM jsonb_array_elements(p_assignments) AS assignment(value)
    WHERE NOT (assignment.value ? 'fields')
        OR jsonb_typeof(assignment.value->'fields') <> 'array'
    LIMIT 1;

    IF invalid_assignment_field_slug IS NOT NULL THEN
        RAISE EXCEPTION 'sync_assignments expected fields to be an array for assignment: %', invalid_assignment_field_slug
            USING ERRCODE = '22023';
    END IF;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.slug
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text
        )
    )
    SELECT input_fields.assignment_slug || '/' || input_fields.slug INTO duplicate_field_key
    FROM input_fields
    GROUP BY input_fields.assignment_slug, input_fields.slug
    HAVING count(*) > 1
    LIMIT 1;

    IF duplicate_field_key IS NOT NULL THEN
        RAISE EXCEPTION 'sync_assignments received duplicate assignment field key: %', duplicate_field_key
            USING ERRCODE = '23505';
    END IF;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text
        )
    )
    SELECT count(*)::integer INTO inserted_count
    FROM input_assignments input_assignment
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.assignments existing_assignment
        WHERE existing_assignment.slug = input_assignment.slug
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            points_possible smallint,
            is_draft boolean,
            is_markdown boolean,
            is_team boolean,
            title text,
            body text,
            closed_at timestamptz
        )
    )
    SELECT count(*)::integer INTO updated_count
    FROM input_assignments input_assignment
    JOIN api.assignments existing_assignment
        ON existing_assignment.slug = input_assignment.slug
    WHERE (
        existing_assignment.points_possible,
        existing_assignment.is_draft,
        existing_assignment.is_markdown,
        existing_assignment.is_team,
        existing_assignment.title,
        existing_assignment.body,
        existing_assignment.closed_at
    ) IS DISTINCT FROM (
        input_assignment.points_possible,
        COALESCE(input_assignment.is_draft, existing_assignment.is_draft),
        COALESCE(input_assignment.is_markdown, existing_assignment.is_markdown),
        COALESCE(input_assignment.is_team, existing_assignment.is_team),
        input_assignment.title,
        input_assignment.body,
        input_assignment.closed_at
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            points_possible smallint,
            is_draft boolean,
            is_markdown boolean,
            is_team boolean,
            title text,
            body text,
            closed_at timestamptz
        )
    )
    SELECT count(*)::integer INTO unchanged_count
    FROM input_assignments input_assignment
    JOIN api.assignments existing_assignment
        ON existing_assignment.slug = input_assignment.slug
    WHERE NOT (
        (
            existing_assignment.points_possible,
            existing_assignment.is_draft,
            existing_assignment.is_markdown,
            existing_assignment.is_team,
            existing_assignment.title,
            existing_assignment.body,
            existing_assignment.closed_at
        ) IS DISTINCT FROM (
            input_assignment.points_possible,
            COALESCE(input_assignment.is_draft, existing_assignment.is_draft),
            COALESCE(input_assignment.is_markdown, existing_assignment.is_markdown),
            COALESCE(input_assignment.is_team, existing_assignment.is_team),
            input_assignment.title,
            input_assignment.body,
            input_assignment.closed_at
        )
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text
        )
    )
    SELECT
        CASE
            WHEN p_delete_missing THEN count(*)::integer
            ELSE 0
        END
        INTO deleted_count
    FROM api.assignments existing_assignment
    WHERE NOT EXISTS (
        SELECT 1
        FROM input_assignments input_assignment
        WHERE input_assignment.slug = existing_assignment.slug
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.slug
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text
        )
    )
    SELECT count(*)::integer INTO field_inserted_count
    FROM input_fields input_field
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.assignment_fields existing_field
        WHERE existing_field.assignment_slug = input_field.assignment_slug
            AND existing_field.slug = input_field.slug
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    )
    SELECT count(*)::integer INTO field_updated_count
    FROM input_fields input_field
    JOIN api.assignment_fields existing_field
        ON existing_field.assignment_slug = input_field.assignment_slug
        AND existing_field.slug = input_field.slug
    WHERE (
        existing_field.label,
        existing_field.help,
        existing_field.placeholder,
        existing_field.is_url,
        existing_field.is_multiline,
        existing_field.display_order,
        existing_field.pattern,
        existing_field.example
    ) IS DISTINCT FROM (
        input_field.label,
        input_field.help,
        input_field.placeholder,
        COALESCE(input_field.is_url, existing_field.is_url),
        COALESCE(input_field.is_multiline, existing_field.is_multiline),
        COALESCE(input_field.display_order, existing_field.display_order),
        COALESCE(input_field.pattern, existing_field.pattern),
        COALESCE(input_field.example, existing_field.example)
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    )
    SELECT count(*)::integer INTO field_unchanged_count
    FROM input_fields input_field
    JOIN api.assignment_fields existing_field
        ON existing_field.assignment_slug = input_field.assignment_slug
        AND existing_field.slug = input_field.slug
    WHERE NOT (
        (
            existing_field.label,
            existing_field.help,
            existing_field.placeholder,
            existing_field.is_url,
            existing_field.is_multiline,
            existing_field.display_order,
            existing_field.pattern,
            existing_field.example
        ) IS DISTINCT FROM (
            input_field.label,
            input_field.help,
            input_field.placeholder,
            COALESCE(input_field.is_url, existing_field.is_url),
            COALESCE(input_field.is_multiline, existing_field.is_multiline),
            COALESCE(input_field.display_order, existing_field.display_order),
            COALESCE(input_field.pattern, existing_field.pattern),
            COALESCE(input_field.example, existing_field.example)
        )
    );

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.slug
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text
        )
    )
    SELECT count(*)::integer INTO field_deleted_count
    FROM api.assignment_fields existing_field
    WHERE (
            p_delete_missing
            OR EXISTS (
                SELECT 1
                FROM input_assignments input_assignment
                WHERE input_assignment.slug = existing_field.assignment_slug
            )
        )
        AND NOT EXISTS (
            SELECT 1
            FROM input_fields input_field
            WHERE input_field.assignment_slug = existing_field.assignment_slug
                AND input_field.slug = existing_field.slug
        );

    IF p_dry_run THEN
        RETURN NEXT;
        RETURN;
    END IF;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    ),
    deleted_fields AS (
        DELETE FROM api.assignment_fields existing_field
        WHERE (
                p_delete_missing
                OR EXISTS (
                    SELECT 1
                    FROM input_assignments input_assignment
                    WHERE input_assignment.slug = existing_field.assignment_slug
                )
            )
            AND NOT EXISTS (
                SELECT 1
                FROM input_fields input_field
                WHERE input_field.assignment_slug = existing_field.assignment_slug
                    AND input_field.slug = existing_field.slug
            )
        RETURNING existing_field.slug, existing_field.assignment_slug
    )
    SELECT count(*)::integer INTO field_deleted_count
    FROM deleted_fields;

    IF p_delete_missing THEN
        WITH input_assignments AS (
            SELECT *
            FROM jsonb_to_recordset(p_assignments) AS assignment (
                slug text
            )
        ),
        deleted_assignments AS (
            DELETE FROM api.assignments existing_assignment
            WHERE NOT EXISTS (
                SELECT 1
                FROM input_assignments input_assignment
                WHERE input_assignment.slug = existing_assignment.slug
            )
            RETURNING existing_assignment.slug
        )
        SELECT count(*)::integer INTO deleted_count
        FROM deleted_assignments;
    ELSE
        deleted_count := 0;
    END IF;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            points_possible smallint,
            is_draft boolean,
            is_markdown boolean,
            is_team boolean,
            title text,
            body text,
            closed_at timestamptz
        )
    ),
    updated_assignments AS (
        UPDATE api.assignments existing_assignment
        SET
            points_possible = input_assignment.points_possible,
            is_draft = COALESCE(input_assignment.is_draft, existing_assignment.is_draft),
            is_markdown = COALESCE(input_assignment.is_markdown, existing_assignment.is_markdown),
            is_team = COALESCE(input_assignment.is_team, existing_assignment.is_team),
            title = input_assignment.title,
            body = input_assignment.body,
            closed_at = input_assignment.closed_at
        FROM input_assignments input_assignment
        WHERE existing_assignment.slug = input_assignment.slug
            AND (
                existing_assignment.points_possible,
                existing_assignment.is_draft,
                existing_assignment.is_markdown,
                existing_assignment.is_team,
                existing_assignment.title,
                existing_assignment.body,
                existing_assignment.closed_at
            ) IS DISTINCT FROM (
                input_assignment.points_possible,
                COALESCE(input_assignment.is_draft, existing_assignment.is_draft),
                COALESCE(input_assignment.is_markdown, existing_assignment.is_markdown),
                COALESCE(input_assignment.is_team, existing_assignment.is_team),
                input_assignment.title,
                input_assignment.body,
                input_assignment.closed_at
            )
        RETURNING existing_assignment.slug
    )
    SELECT count(*)::integer INTO updated_count
    FROM updated_assignments;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            points_possible smallint,
            is_draft boolean,
            is_markdown boolean,
            is_team boolean,
            title text,
            body text,
            closed_at timestamptz
        )
    ),
    inserted_assignments AS (
        INSERT INTO api.assignments (
            slug,
            points_possible,
            is_draft,
            is_markdown,
            is_team,
            title,
            body,
            closed_at
        )
        SELECT
            input_assignment.slug,
            input_assignment.points_possible,
            COALESCE(input_assignment.is_draft, true),
            COALESCE(input_assignment.is_markdown, false),
            COALESCE(input_assignment.is_team, false),
            input_assignment.title,
            input_assignment.body,
            input_assignment.closed_at
        FROM input_assignments input_assignment
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.assignments existing_assignment
            WHERE existing_assignment.slug = input_assignment.slug
        )
        RETURNING slug
    )
    SELECT count(*)::integer INTO inserted_count
    FROM inserted_assignments;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    ),
    updated_fields AS (
        UPDATE api.assignment_fields existing_field
        SET
            label = input_field.label,
            help = input_field.help,
            placeholder = input_field.placeholder,
            is_url = COALESCE(input_field.is_url, existing_field.is_url),
            is_multiline = COALESCE(input_field.is_multiline, existing_field.is_multiline),
            display_order = COALESCE(input_field.display_order, existing_field.display_order),
            pattern = COALESCE(input_field.pattern, existing_field.pattern),
            example = COALESCE(input_field.example, existing_field.example)
        FROM input_fields input_field
        WHERE existing_field.assignment_slug = input_field.assignment_slug
            AND existing_field.slug = input_field.slug
            AND (
                existing_field.label,
                existing_field.help,
                existing_field.placeholder,
                existing_field.is_url,
                existing_field.is_multiline,
                existing_field.display_order,
                existing_field.pattern,
                existing_field.example
            ) IS DISTINCT FROM (
                input_field.label,
                input_field.help,
                input_field.placeholder,
                COALESCE(input_field.is_url, existing_field.is_url),
                COALESCE(input_field.is_multiline, existing_field.is_multiline),
                COALESCE(input_field.display_order, existing_field.display_order),
                COALESCE(input_field.pattern, existing_field.pattern),
                COALESCE(input_field.example, existing_field.example)
            )
        RETURNING existing_field.slug, existing_field.assignment_slug
    )
    SELECT count(*)::integer INTO field_updated_count
    FROM updated_fields;

    WITH input_assignments AS (
        SELECT *
        FROM jsonb_to_recordset(p_assignments) AS assignment (
            slug text,
            fields jsonb
        )
    ),
    input_fields AS (
        SELECT
            input_assignment.slug AS assignment_slug,
            input_field.*
        FROM input_assignments input_assignment
        CROSS JOIN LATERAL jsonb_to_recordset(input_assignment.fields) AS input_field (
            slug text,
            label text,
            help text,
            placeholder text,
            is_url boolean,
            is_multiline boolean,
            display_order smallint,
            pattern text,
            example text
        )
    ),
    inserted_fields AS (
        INSERT INTO api.assignment_fields (
            slug,
            assignment_slug,
            label,
            help,
            placeholder,
            is_url,
            is_multiline,
            display_order,
            pattern,
            example
        )
        SELECT
            input_field.slug,
            input_field.assignment_slug,
            input_field.label,
            input_field.help,
            input_field.placeholder,
            COALESCE(input_field.is_url, false),
            COALESCE(input_field.is_multiline, false),
            COALESCE(input_field.display_order, 0),
            COALESCE(input_field.pattern, '.*'),
            COALESCE(input_field.example, '')
        FROM input_fields input_field
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.assignment_fields existing_field
            WHERE existing_field.assignment_slug = input_field.assignment_slug
                AND existing_field.slug = input_field.slug
        )
        RETURNING slug, assignment_slug
    )
    SELECT count(*)::integer INTO field_inserted_count
    FROM inserted_fields;

    RETURN NEXT;
END;
$$;


ALTER FUNCTION api.sync_assignments(p_assignments jsonb, p_delete_missing boolean, p_dry_run boolean) OWNER TO superuser;

--
-- Name: sync_meetings(jsonb); Type: FUNCTION; Schema: api; Owner: superuser
--

CREATE FUNCTION api.sync_meetings(p_meetings jsonb) RETURNS TABLE(inserted_count integer, updated_count integer, unchanged_count integer, deleted_count integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    input_count integer;
    duplicate_slug text;
BEGIN
    IF p_meetings IS NULL OR jsonb_typeof(p_meetings) <> 'array' THEN
        RAISE EXCEPTION 'sync_meetings expects a JSON array'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_meetings);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'sync_meetings refuses to sync an empty meeting list'
            USING ERRCODE = '22023';
    END IF;

    SELECT meeting.slug INTO duplicate_slug
    FROM jsonb_to_recordset(p_meetings) AS meeting (
        slug text,
        title text,
        summary text,
        description text,
        begins_at timestamptz,
        duration interval,
        is_draft boolean
    )
    GROUP BY meeting.slug
    HAVING count(*) > 1
    LIMIT 1;

    IF duplicate_slug IS NOT NULL THEN
        RAISE EXCEPTION 'sync_meetings received duplicate meeting slug: %', duplicate_slug
            USING ERRCODE = '23505';
    END IF;

    WITH input_meetings AS (
        SELECT *
        FROM jsonb_to_recordset(p_meetings) AS meeting (
            slug text,
            title text,
            summary text,
            description text,
            begins_at timestamptz,
            duration interval,
            is_draft boolean
        )
    ),
    deleted_meetings AS (
        DELETE FROM api.meetings existing_meeting
        WHERE NOT EXISTS (
            SELECT 1
            FROM input_meetings input_meeting
            WHERE input_meeting.slug = existing_meeting.slug
        )
        RETURNING existing_meeting.slug
    )
    SELECT count(*)::integer INTO deleted_count
    FROM deleted_meetings;

    WITH input_meetings AS (
        SELECT *
        FROM jsonb_to_recordset(p_meetings) AS meeting (
            slug text,
            title text,
            summary text,
            description text,
            begins_at timestamptz,
            duration interval,
            is_draft boolean
        )
    )
    SELECT count(*)::integer INTO unchanged_count
    FROM input_meetings input_meeting
    JOIN api.meetings existing_meeting
        ON existing_meeting.slug = input_meeting.slug
    WHERE NOT (
        (
            existing_meeting.title,
            existing_meeting.summary,
            existing_meeting.description,
            existing_meeting.begins_at,
            existing_meeting.duration,
            existing_meeting.is_draft
        ) IS DISTINCT FROM (
            input_meeting.title,
            input_meeting.summary,
            input_meeting.description,
            input_meeting.begins_at,
            input_meeting.duration,
            input_meeting.is_draft
        )
    );

    WITH input_meetings AS (
        SELECT *
        FROM jsonb_to_recordset(p_meetings) AS meeting (
            slug text,
            title text,
            summary text,
            description text,
            begins_at timestamptz,
            duration interval,
            is_draft boolean
        )
    ),
    changed_meetings AS (
        SELECT input_meeting.*
        FROM input_meetings input_meeting
        JOIN api.meetings existing_meeting
            ON existing_meeting.slug = input_meeting.slug
        WHERE (
            existing_meeting.title,
            existing_meeting.summary,
            existing_meeting.description,
            existing_meeting.begins_at,
            existing_meeting.duration,
            existing_meeting.is_draft
        ) IS DISTINCT FROM (
            input_meeting.title,
            input_meeting.summary,
            input_meeting.description,
            input_meeting.begins_at,
            input_meeting.duration,
            input_meeting.is_draft
        )
    ),
    updated_meetings AS (
        UPDATE api.meetings existing_meeting
        SET
            title = input_meeting.title,
            summary = input_meeting.summary,
            description = input_meeting.description,
            begins_at = input_meeting.begins_at,
            duration = input_meeting.duration,
            is_draft = input_meeting.is_draft
        FROM changed_meetings input_meeting
        WHERE existing_meeting.slug = input_meeting.slug
        RETURNING existing_meeting.slug
    )
    SELECT count(*)::integer INTO updated_count
    FROM updated_meetings;

    WITH input_meetings AS (
        SELECT *
        FROM jsonb_to_recordset(p_meetings) AS meeting (
            slug text,
            title text,
            summary text,
            description text,
            begins_at timestamptz,
            duration interval,
            is_draft boolean
        )
    ),
    inserted_meetings AS (
        INSERT INTO api.meetings (
            slug,
            title,
            summary,
            description,
            begins_at,
            duration,
            is_draft
        )
        SELECT
            input_meeting.slug,
            input_meeting.title,
            input_meeting.summary,
            input_meeting.description,
            input_meeting.begins_at,
            input_meeting.duration,
            input_meeting.is_draft
        FROM input_meetings input_meeting
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.meetings existing_meeting
            WHERE existing_meeting.slug = input_meeting.slug
        )
        RETURNING slug
    )
    SELECT count(*)::integer INTO inserted_count
    FROM inserted_meetings;

    RETURN NEXT;
END;
$$;


-- Name: assignment_field_submission_is_writable_by_current_user(integer); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.assignment_field_submission_is_writable_by_current_user(the_assignment_submission_id integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION data.assignment_field_submission_is_writable_by_current_user(the_assignment_submission_id integer) OWNER TO superuser;

--
-- Name: clean_user_fields(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.clean_user_fields() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.email := lower(NEW.email);
    NEW.netid := lower(NEW.netid);
    NEW.nickname := lower(NEW.nickname);
    NEW.updated_at = current_timestamp;
    return NEW;
END;
$$;


ALTER FUNCTION data.clean_user_fields() OWNER TO superuser;

--
-- Name: fill_assignment_field_submission_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_assignment_field_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Fill in the assignment_slug if it is NULL by looking
    -- at the assignment_slug from the assignment_submission.
    IF (NEW.assignment_slug IS NULL AND NEW.assignment_submission_id IS NOT NULL) THEN
        SELECT assignment_slug INTO NEW.assignment_slug
        FROM data.assignment_submission
        WHERE id = NEW.assignment_submission_id;
    END IF;
    -- Fill in the assignment_submission_id if it is null
    -- by looking at the assignment if the assignment_slug
    -- is not null.
    IF (NEW.assignment_submission_id IS NULL and NEW.assignment_slug IS NOT NULL and request.user_id() IS NOT NULL) THEN
        SELECT ass.id INTO NEW.assignment_submission_id
        FROM
            (data.assignment_submission ass
            LEFT OUTER JOIN data."user" u
            ON u.team_nickname = ass.team_nickname)
        WHERE (
            -- It is the right assignment
            assignment_slug = NEW.assignment_slug
            AND
            -- It is theirs or their teams assignment submission
            (u.id = request.user_id() OR user_id = request.user_id())
        );
    END IF;

    -- Try to fill in the `submitter_user_id`
    IF (request.user_id() IS NULL ) THEN
        IF (NEW.submitter_user_id IS NULL ) THEN
            -- In practice this should only be the case when an
            -- administrator is using the database directly and
            -- not through the API.
            SELECT submitter_user_id INTO NEW.submitter_user_id
            FROM data.assignment_submission AS sub
            WHERE sub.id = NEW.assignment_submission_id;
        END IF;
    ELSE
        NEW.submitter_user_id = request.user_id();
    END IF;

    -- Try to fill in `pattern`
    IF (NEW.assignment_field_pattern is NULL) THEN
        SELECT pattern INTO NEW.assignment_field_pattern
        FROM data.assignment_field AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    -- Try to fill in `is_url`
    IF (NEW.assignment_field_is_url is NULL) THEN
        SELECT is_url INTO NEW.assignment_field_is_url
        FROM data.assignment_field AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_field_submission_defaults() OWNER TO superuser;

--
-- Name: fill_assignment_grade_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_assignment_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT ass_sub.assignment_slug INTO NEW.assignment_slug
        FROM data.assignment_submission AS ass_sub
        WHERE ass_sub.id = NEW.assignment_submission_id;
    END IF;
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM data.assignment
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_grade_defaults() OWNER TO superuser;

--
-- Name: fill_assignment_grade_exception_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_assignment_grade_exception_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM data.assignment
        WHERE slug = NEW.assignment_slug;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_grade_exception_defaults() OWNER TO superuser;

--
-- Name: fill_assignment_submission_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_assignment_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Set default is_team from assignment table
    IF (NEW.is_team IS NULL) THEN
        SELECT is_team INTO NEW.is_team
        FROM data.assignment
        WHERE slug = NEW.assignment_slug;
    END IF;
    -- Set default user_id from request credentials
    IF (NEW.user_id IS NULL AND NOT NEW.is_team ) THEN
        NEW.user_id = request.user_id();
    END IF;
    -- Set default submitter_user_id. This is done in 
    -- the table defaults, but we do it here so that
    -- we can fill in team nickname below.
    IF (NEW.submitter_user_id IS NULL ) THEN
        IF (request.user_id() IS NULL ) THEN
            IF (NEW.user_id IS NOT NULL) THEN
                NEW.submitter_user_id = NEW.user_id;
            END IF;
        ELSE
            NEW.submitter_user_id = request.user_id();
        END IF;
    END IF;
    -- Set default team_nickname from user table
    IF (NEW.is_team AND NEW.team_nickname IS NULL) THEN
        SELECT u.team_nickname INTO NEW.team_nickname
        FROM data."user" AS u
        WHERE u.id = NEW.submitter_user_id;
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_assignment_submission_defaults() OWNER TO superuser;

--
-- Name: fill_grade_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_grade_defaults() OWNER TO superuser;

--
-- Name: fill_grade_snapshot_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_grade_snapshot_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_grade_snapshot_defaults() OWNER TO superuser;

--
-- Name: fill_quiz_grade_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_quiz_grade_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Fill in the quiz_id if it is null
    IF (NEW.points_possible IS NULL) THEN
        SELECT points_possible INTO NEW.points_possible
        FROM data.quiz
        WHERE id = NEW.quiz_id;
    END IF;
    IF (NEW.user_id IS NULL and request.user_id() IS NOT NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_quiz_grade_defaults() OWNER TO superuser;

--
-- Name: fill_quiz_submission_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_quiz_submission_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF (NEW.user_id IS NULL) THEN
        NEW.user_id = request.user_id();
    END IF;
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_quiz_submission_defaults() OWNER TO superuser;

--
-- Name: fill_user_secret_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.fill_user_secret_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.fill_user_secret_defaults() OWNER TO superuser;

--
-- Name: quiz_set_defaults(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.quiz_set_defaults() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
  IF (NEW.closed_at IS NULL) THEN
    SELECT begins_at INTO NEW.closed_at
    FROM data.meeting
    WHERE slug = NEW.meeting_slug;
  END IF;
  IF (NEW.open_at IS NULL) THEN
    SELECT (begins_at - '5 days'::INTERVAL) INTO NEW.open_at
    FROM data.meeting
    WHERE slug = NEW.meeting_slug;
  END IF;
  NEW.updated_at = current_timestamp;
  RETURN NEW;
END; $$;


ALTER FUNCTION data.quiz_set_defaults() OWNER TO superuser;

--
-- Name: refresh_assignment_submission_participants(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.refresh_assignment_submission_participants() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'data', 'pg_temp'
    AS $$
BEGIN
    -- Submission participants are an insert-time snapshot. Later team roster
    -- changes must not rewrite historical submitted work.
    DELETE FROM data.assignment_submission_participant
    WHERE assignment_submission_id = NEW.id;

    IF (NEW.is_team) THEN
        INSERT INTO data.assignment_submission_participant (assignment_submission_id, user_id)
        SELECT NEW.id, u.id
        FROM data."user" AS u
        WHERE u.team_nickname = NEW.team_nickname;
    ELSE
        INSERT INTO data.assignment_submission_participant (assignment_submission_id, user_id)
        SELECT NEW.id, NEW.user_id
        WHERE NEW.user_id IS NOT NULL;
    END IF;

    RETURN NULL;
END;
$$;


ALTER FUNCTION data.refresh_assignment_submission_participants() OWNER TO superuser;

--
-- Name: text_is_url(text); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.text_is_url(text) RETURNS boolean
    LANGUAGE sql STABLE
    RETURN $1 ~* '^https?://[a-z0-9]+';


ALTER FUNCTION data.text_is_url(text) OWNER TO superuser;

--
-- Name: text_matches(text, text); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.text_matches(text, text) RETURNS boolean
    LANGUAGE sql STABLE
    RETURN $1 ~ ('^(?:' || $2 || ')$');


ALTER FUNCTION data.text_matches(text, text) OWNER TO superuser;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: data; Owner: superuser
--

CREATE FUNCTION data.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$;


ALTER FUNCTION data.update_updated_at_column() OWNER TO superuser;

--
-- Name: algorithm_sign(text, text, text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.algorithm_sign(signables text, secret text, algorithm text) RETURNS text
    LANGUAGE sql
    AS $$
WITH
  alg AS (
    SELECT CASE
      WHEN algorithm = 'HS256' THEN 'sha256'
      WHEN algorithm = 'HS384' THEN 'sha384'
      WHEN algorithm = 'HS512' THEN 'sha512'
      ELSE '' END)  -- hmac throws error
SELECT pgjwt.url_encode(public.hmac(signables, secret, (select * FROM alg)));
$$;


ALTER FUNCTION pgjwt.algorithm_sign(signables text, secret text, algorithm text) OWNER TO superuser;

--
-- Name: sign(json, text, text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.sign(payload json, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS text
    LANGUAGE sql
    AS $$
WITH
  header AS (
    SELECT pgjwt.url_encode(convert_to('{"alg":"' || algorithm || '","typ":"JWT"}', 'utf8'))
    ),
  payload AS (
    SELECT pgjwt.url_encode(convert_to(payload::text, 'utf8'))
    ),
  signables AS (
    SELECT (SELECT * FROM header) || '.' || (SELECT * FROM payload)
    )
SELECT
    (SELECT * FROM signables)
    || '.' ||
    pgjwt.algorithm_sign((SELECT * FROM signables), secret, algorithm);
$$;


ALTER FUNCTION pgjwt.sign(payload json, secret text, algorithm text) OWNER TO superuser;

--
-- Name: url_decode(text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.url_decode(data text) RETURNS bytea
    LANGUAGE sql
    AS $$
WITH t AS (SELECT translate(data, '-_', '+/')),
     rem AS (SELECT length((SELECT * FROM t)) % 4) -- compute padding size
    SELECT decode(
        (SELECT * FROM t) ||
        CASE WHEN (SELECT * FROM rem) > 0
           THEN repeat('=', (4 - (SELECT * FROM rem)))
           ELSE '' END,
    'base64');
$$;


ALTER FUNCTION pgjwt.url_decode(data text) OWNER TO superuser;

--
-- Name: url_encode(bytea); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.url_encode(data bytea) RETURNS text
    LANGUAGE sql
    AS $$
    SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;


ALTER FUNCTION pgjwt.url_encode(data bytea) OWNER TO superuser;

--
-- Name: verify(text, text, text); Type: FUNCTION; Schema: pgjwt; Owner: superuser
--

CREATE FUNCTION pgjwt.verify(token text, secret text, algorithm text DEFAULT 'HS256'::text) RETURNS TABLE(header json, payload json, valid boolean)
    LANGUAGE sql
    AS $$
  SELECT
    convert_from(pgjwt.url_decode(r[1]), 'utf8')::json AS header,
    convert_from(pgjwt.url_decode(r[2]), 'utf8')::json AS payload,
    r[3] = pgjwt.algorithm_sign(r[1] || '.' || r[2], secret, algorithm) AS valid
  FROM regexp_split_to_array(token, '\.') r;
$$;


ALTER FUNCTION pgjwt.verify(token text, secret text, algorithm text) OWNER TO superuser;

--
-- Name: app_name(); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.app_name() RETURNS text
    LANGUAGE sql STABLE
    RETURN coalesce(current_setting('request.jwt.claim.app_name', TRUE), (current_setting('request.jwt.claims', TRUE)::json ->> 'app_name'));


ALTER FUNCTION request.app_name() OWNER TO superuser;

-- Name: user_id_as_text(); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.user_id_as_text() RETURNS text
    LANGUAGE sql STABLE
    RETURN coalesce(current_setting('request.jwt.claim.user_id', TRUE), (current_setting('request.jwt.claims', TRUE)::json ->> 'user_id'));


ALTER FUNCTION request.user_id_as_text() OWNER TO superuser;

--
-- Name: user_id(); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.user_id() RETURNS integer
    LANGUAGE sql STABLE
    RETURN
        CASE request.user_id_as_text ()
        WHEN '' THEN
            0
        ELSE
            request.user_id_as_text ()::int
        END;


ALTER FUNCTION request.user_id() OWNER TO superuser;

--
-- Name: user_role(); Type: FUNCTION; Schema: request; Owner: superuser
--

CREATE FUNCTION request.user_role() RETURNS text
    LANGUAGE sql STABLE
    RETURN coalesce(current_setting('request.jwt.claim.role', TRUE), (current_setting('request.jwt.claims', TRUE)::json ->> 'role'));


ALTER FUNCTION request.user_role() OWNER TO superuser;

--
-- Name: secrets; Type: TABLE; Schema: settings; Owner: superuser
--

CREATE TABLE settings.secrets (
    key text NOT NULL,
    value text NOT NULL
);


ALTER TABLE settings.secrets OWNER TO superuser;

--
-- Name: get(text); Type: FUNCTION; Schema: settings; Owner: superuser
--

CREATE FUNCTION settings.get(text) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'settings', 'pg_temp'
    RETURN (select value from settings.secrets where key = $1);


ALTER FUNCTION settings.get(text) OWNER TO superuser;

--
-- Name: set(text, text); Type: FUNCTION; Schema: settings; Owner: superuser
--

CREATE FUNCTION settings.set(text, text) RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'settings', 'pg_temp'
BEGIN ATOMIC
	insert into settings.secrets (key, value)
	values ($1, $2)
	on conflict (key) do update
	set value = $2;
END;


ALTER FUNCTION settings.set(text, text) OWNER TO superuser;

--
-- Name: sign_jwt(integer, data.user_role); Type: FUNCTION; Schema: auth; Owner: superuser
--

CREATE FUNCTION auth.sign_jwt(user_id integer, role data.user_role) RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'auth', 'settings', 'pgjwt', 'pg_temp'
    RETURN pgjwt.sign(
      json_build_object(
        'user_id', user_id,
        'role', "role"::TEXT,
        'exp', extract(epoch from now())::integer + settings.get('jwt_lifetime')::int -- token expires in 1 hour
      ),
      settings.get('jwt_secret'));


ALTER FUNCTION auth.sign_jwt(user_id integer, role data.user_role) OWNER TO superuser;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: assignment_field_submission; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_field_submission (
    assignment_submission_id integer NOT NULL,
    assignment_field_slug text NOT NULL,
    assignment_slug text NOT NULL,
    assignment_field_is_url boolean NOT NULL,
    assignment_field_pattern text NOT NULL,
    body text NOT NULL,
    submitter_user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT body_matches_is_url CHECK (((assignment_field_is_url IS FALSE) OR data.text_is_url(body))),
    CONSTRAINT body_matches_pattern CHECK (data.text_matches(body, assignment_field_pattern))
);


ALTER TABLE data.assignment_field_submission OWNER TO superuser;

--
-- Name: assignment_field_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_field_submissions AS
 SELECT assignment_submission_id,
    assignment_field_slug,
    assignment_slug,
    assignment_field_is_url,
    assignment_field_pattern,
    body,
    submitter_user_id,
    created_at,
    updated_at
   FROM data.assignment_field_submission;


ALTER VIEW api.assignment_field_submissions OWNER TO api;

--
-- Name: assignment_field; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_field (
    slug text NOT NULL,
    assignment_slug text NOT NULL,
    label text NOT NULL,
    help text NOT NULL,
    placeholder text NOT NULL,
    is_url boolean DEFAULT false NOT NULL,
    is_multiline boolean DEFAULT false NOT NULL,
    display_order smallint DEFAULT 0 NOT NULL,
    pattern text DEFAULT '.*'::text NOT NULL,
    example text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_field_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT assignment_field_help_check CHECK ((char_length(help) < 200)),
    CONSTRAINT assignment_field_label_check CHECK ((char_length(label) < 100)),
    CONSTRAINT assignment_field_placeholder_check CHECK ((char_length(placeholder) < 100)),
    CONSTRAINT assignment_field_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 30))),
    CONSTRAINT pattern_matches_example CHECK (data.text_matches(example, pattern)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT url_matches_example CHECK (((is_url IS FALSE) OR ((is_url IS TRUE) AND data.text_is_url(example)))),
    CONSTRAINT url_not_multiline CHECK ((NOT (is_url AND is_multiline)))
);


ALTER TABLE data.assignment_field OWNER TO superuser;

-- Name: artifact; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.artifact (
    id integer NOT NULL,
    user_id integer NOT NULL,
    quiz_id integer,
    slug text NOT NULL,
    title text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    url text NOT NULL,
    storage_uri text,
    content_type text,
    content_length bigint,
    checksum_sha256 text,
    is_user_visible boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT artifact_checksum_sha256_check CHECK (((checksum_sha256 IS NULL) OR (checksum_sha256 ~ '^[a-f0-9]{64}$'::text))),
    CONSTRAINT artifact_content_length_check CHECK (((content_length IS NULL) OR (content_length >= 0))),
    CONSTRAINT artifact_content_type_check CHECK (((content_type IS NULL) OR (content_type ~ '^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*$'::text))),
    CONSTRAINT artifact_description_check CHECK ((char_length(description) < 1000)),
    CONSTRAINT artifact_slug_check CHECK (((slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$'::text) AND (char_length(slug) < 100))),
    CONSTRAINT artifact_storage_uri_check CHECK (((storage_uri IS NULL) OR (char_length(storage_uri) < 1000))),
    CONSTRAINT artifact_title_check CHECK ((char_length(title) < 200)),
    CONSTRAINT artifact_url_check CHECK (data.text_is_url(url)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.artifact OWNER TO superuser;

--
-- Name: artifacts; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.artifacts AS
 SELECT id,
    user_id,
    quiz_id,
    slug,
    title,
    description,
    url,
    storage_uri,
    content_type,
    content_length,
    checksum_sha256,
    is_user_visible,
    created_at,
    updated_at
   FROM data.artifact;


ALTER VIEW api.artifacts OWNER TO api;

--
-- Name: assignment_grade; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_grade (
    assignment_slug text NOT NULL,
    points_possible smallint NOT NULL,
    assignment_submission_id integer NOT NULL,
    points real NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_grade_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_grade OWNER TO superuser;

--
-- Name: assignment_submission; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_submission (
    id integer NOT NULL,
    assignment_slug text NOT NULL,
    is_team boolean NOT NULL,
    user_id integer,
    team_nickname text,
    submitter_user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_submission_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT assignment_submission_team_nickname_check CHECK ((char_length(team_nickname) < 50)),
    CONSTRAINT matches_assignment_is_team CHECK (((is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((NOT is_team) AND (team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT submitter_matches_user_id CHECK ((is_team OR ((NOT is_team) AND (user_id = submitter_user_id)))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_submission OWNER TO superuser;

--
-- Name: assignment_submission_participant; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_submission_participant (
    assignment_submission_id integer CONSTRAINT assignment_submission_partici_assignment_submission_id_not_null NOT NULL,
    user_id integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE data.assignment_submission_participant OWNER TO superuser;

--
-- Name: user; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data."user" (
    id integer NOT NULL,
    email text,
    netid text NOT NULL,
    name text,
    lastname text,
    organization text,
    known_as text,
    nickname text NOT NULL,
    role data.user_role DEFAULT (settings.get('auth.default-role'::text))::data.user_role NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    team_nickname text,
    CONSTRAINT user_check CHECK ((updated_at >= created_at)),
    CONSTRAINT user_email_check CHECK (((email ~ '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'::text) AND (char_length(email) < 100))),
    CONSTRAINT user_known_as_check CHECK ((char_length(known_as) < 50)),
    CONSTRAINT user_lastname_check CHECK ((char_length(lastname) < 100)),
    CONSTRAINT user_name_check CHECK ((char_length(name) < 100)),
    CONSTRAINT user_netid_check CHECK (((netid ~ '^[a-z]+[0-9]+$'::text) AND (char_length(netid) < 10))),
    CONSTRAINT user_nickname_check CHECK (((nickname ~ '^[\w]{2,20}-[\w]{2,20}$'::text) AND (char_length(nickname) < 50))),
    CONSTRAINT user_organization_check CHECK ((char_length(organization) < 200)),
    CONSTRAINT user_team_nickname_check CHECK ((char_length(team_nickname) < 50))
);


ALTER TABLE data."user" OWNER TO superuser;

--
-- Name: assignment_grade_distributions; Type: VIEW; Schema: api; Owner: superuser
--

CREATE VIEW api.assignment_grade_distributions AS
 SELECT sub.assignment_slug,
    count(sub.id) AS count,
    avg(assignment_grade.points) AS average,
    min(assignment_grade.points) AS min,
    max(assignment_grade.points) AS max,
    max(assignment_grade.points_possible) AS points_possible,
    stddev_pop(assignment_grade.points) AS stddev,
    array_agg(assignment_grade.points ORDER BY assignment_grade.points) AS grades
   FROM (((data.assignment_grade
     JOIN data.assignment_submission sub ON ((assignment_grade.assignment_submission_id = sub.id)))
     JOIN data.assignment_submission_participant participant ON ((participant.assignment_submission_id = sub.id)))
     JOIN data."user" u ON ((participant.user_id = u.id)))
  WHERE (u.role = 'student'::data.user_role)
  GROUP BY sub.assignment_slug
 HAVING (count(sub.id) >= 3);


ALTER VIEW api.assignment_grade_distributions OWNER TO superuser;

--
-- Name: VIEW assignment_grade_distributions; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON VIEW api.assignment_grade_distributions IS 'Statics on the grades received by students for each assignment';


--
-- Name: COLUMN assignment_grade_distributions.assignment_slug; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.assignment_slug IS 'The slug for the assignment to which these statistics correspond';


--
-- Name: COLUMN assignment_grade_distributions.count; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.count IS 'The number of students with grades for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.average; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.average IS 'The average grade among students for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.min; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.min IS 'The minmum grade among students for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.max; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.max IS 'The maximum grade among students for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.points_possible; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.points_possible IS 'The number of points possible for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.stddev; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.stddev IS 'The standard deviation of student grades for this assignment';


--
-- Name: COLUMN assignment_grade_distributions.grades; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.assignment_grade_distributions.grades IS 'The grades received by students for this assignment in ascending order';


--
-- Name: assignment_grade_exception; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment_grade_exception (
    id integer NOT NULL,
    assignment_slug text,
    is_team boolean NOT NULL,
    user_id integer,
    team_nickname text,
    fractional_credit numeric DEFAULT 1 NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_grade_exception_assignment_slug_check CHECK ((char_length(assignment_slug) < 100)),
    CONSTRAINT assignment_grade_exception_fractional_credit_check CHECK (((fractional_credit >= (0)::numeric) AND (fractional_credit <= (1)::numeric))),
    CONSTRAINT assignment_grade_exception_team_nickname_check CHECK ((char_length(team_nickname) < 50)),
    CONSTRAINT matches_assignment_is_team CHECK (((is_team AND (team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((NOT is_team) AND (team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment_grade_exception OWNER TO superuser;

--
-- Name: assignment_grade_exceptions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_grade_exceptions AS
 SELECT id,
    assignment_slug,
    is_team,
    user_id,
    team_nickname,
    fractional_credit,
    closed_at,
    created_at,
    updated_at
   FROM data.assignment_grade_exception;


ALTER VIEW api.assignment_grade_exceptions OWNER TO api;

--
-- Name: assignment_grades; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_grades AS
 SELECT assignment_slug,
    points_possible,
    assignment_submission_id,
    points,
    description,
    created_at,
    updated_at
   FROM data.assignment_grade;


ALTER VIEW api.assignment_grades OWNER TO api;

--
-- Name: assignment_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_submissions AS
 SELECT id,
    assignment_slug,
    is_team,
    user_id,
    team_nickname,
    submitter_user_id,
    created_at,
    updated_at
   FROM data.assignment_submission;


ALTER VIEW api.assignment_submissions OWNER TO api;

--
-- Name: assignment; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.assignment (
    slug text NOT NULL,
    points_possible smallint NOT NULL,
    is_draft boolean DEFAULT true NOT NULL,
    is_markdown boolean DEFAULT false,
    is_team boolean DEFAULT false NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT assignment_points_possible_check CHECK ((points_possible >= 0)),
    CONSTRAINT assignment_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 60))),
    CONSTRAINT assignment_title_check CHECK ((char_length(title) < 100)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.assignment OWNER TO superuser;

--
-- Name: assignments; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignments WITH (security_barrier='true') AS
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
  WHERE ((request.user_role() = 'faculty'::text) OR (assignment.is_draft = false));


ALTER VIEW api.assignments OWNER TO api;

--
-- Name: assignment_fields; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.assignment_fields WITH (security_barrier='true') AS
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
           FROM data.assignment
          WHERE ((assignment.slug = field.assignment_slug) AND (assignment.is_draft = false)))));


ALTER VIEW api.assignment_fields OWNER TO api;

--
-- Name: engagement; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.engagement (
    user_id integer NOT NULL,
    meeting_slug text NOT NULL,
    participation data.participation_enum NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT engagement_meeting_slug_check CHECK ((char_length(meeting_slug) < 100)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.engagement OWNER TO superuser;

--
-- Name: engagements; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.engagements AS
 SELECT user_id,
    meeting_slug,
    participation,
    created_at,
    updated_at
   FROM data.engagement;


ALTER VIEW api.engagements OWNER TO api;

--
-- Name: grade_snapshot; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.grade_snapshot (
    slug text NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT grade_snapshot_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 60))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.grade_snapshot OWNER TO superuser;

--
-- Name: grade_snapshots; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.grade_snapshots AS
 SELECT slug,
    description,
    created_at,
    updated_at
   FROM data.grade_snapshot;


ALTER VIEW api.grade_snapshots OWNER TO api;

--
-- Name: VIEW grade_snapshots; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.grade_snapshots IS 'Snapshots of class grades at particular times';


--
-- Name: COLUMN grade_snapshots.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.slug IS 'The slug, or unique identifier, of this grade snapshot';


--
-- Name: COLUMN grade_snapshots.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.description IS 'The description of this grade snapshot. This might tell you how the grades were computed for this snapshot.';


--
-- Name: COLUMN grade_snapshots.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.created_at IS 'When this snapshot was created';


--
-- Name: COLUMN grade_snapshots.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.grade_snapshots.updated_at IS 'When this snapshot was last updated';


--
-- Name: grade; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.grade (
    points real NOT NULL,
    snapshot_slug text CONSTRAINT grade_snapshot_slug_not_null1 NOT NULL,
    user_id integer NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT grade_points_finite_nonnegative CHECK (((points >= (0)::double precision) AND (points < 'Infinity'::real))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.grade OWNER TO superuser;

--
-- Name: grades; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.grades AS
 SELECT points,
    snapshot_slug,
    user_id,
    description,
    created_at,
    updated_at
   FROM data.grade;


ALTER VIEW api.grades OWNER TO api;

--
-- Name: meeting; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.meeting (
    title text NOT NULL,
    slug text NOT NULL,
    summary text,
    description text NOT NULL,
    begins_at timestamp with time zone NOT NULL,
    duration interval NOT NULL,
    is_draft boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT meeting_duration_positive CHECK ((duration > '00:00:00'::interval)),
    CONSTRAINT meeting_slug_check CHECK (((slug ~ '^[a-z0-9-]+$'::text) AND (char_length(slug) < 60))),
    CONSTRAINT meeting_title_check CHECK ((char_length(title) < 250)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.meeting OWNER TO superuser;

--
-- Name: meetings; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.meetings AS
 SELECT title,
    slug,
    summary,
    description,
    begins_at,
    duration,
    is_draft,
    created_at,
    updated_at
   FROM data.meeting;


ALTER VIEW api.meetings OWNER TO api;

--
-- Name: VIEW meetings; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.meetings IS 'An in-person meeting of our class, usually a lecture';


--
-- Name: COLUMN meetings.slug; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.slug IS 'A short identifier, appropriate for URLs, like "sql-intro"';


--
-- Name: COLUMN meetings.summary; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.summary IS 'A short description of the meeting in Markdown format';


--
-- Name: COLUMN meetings.description; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.description IS 'A long description of the meeting in Markdown format';


--
-- Name: COLUMN meetings.begins_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.begins_at IS 'The time at which the meeting begins, including timezone';


--
-- Name: COLUMN meetings.duration; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.duration IS 'The duration of the meeting as a Postgres interval';


--
-- Name: COLUMN meetings.is_draft; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.is_draft IS 'An indicator of if the content is still changing';


--
-- Name: COLUMN meetings.created_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.created_at IS 'The time this database entry was created, including timezone';


--
-- Name: COLUMN meetings.updated_at; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.meetings.updated_at IS 'The most recent time this database entry was updated, including timezone';


--
-- Name: platform_version; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.platform_version AS
 SELECT 'yelukerest'::text AS platform,
    1 AS platform_compatibility_version,
    1 AS schema_compatibility_version,
    4 AS admin_api_version;


ALTER VIEW api.platform_version OWNER TO api;

--
-- Name: VIEW platform_version; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON VIEW api.platform_version IS 'Single-row compatibility metadata for course admin preflight checks';


--
-- Name: COLUMN platform_version.platform; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.platform_version.platform IS 'Platform identifier expected by course admin tooling';


--
-- Name: COLUMN platform_version.platform_compatibility_version; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.platform_version.platform_compatibility_version IS 'Integer compatibility version for Yelukerest platform behavior';


--
-- Name: COLUMN platform_version.schema_compatibility_version; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.platform_version.schema_compatibility_version IS 'Integer compatibility version for database schema/API shape';


--
-- Name: COLUMN platform_version.admin_api_version; Type: COMMENT; Schema: api; Owner: api
--

COMMENT ON COLUMN api.platform_version.admin_api_version IS 'Integer compatibility version for generic admin API operations';


--
-- Name: quiz_grade; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz_grade (
    quiz_id integer NOT NULL,
    points real NOT NULL,
    points_possible smallint NOT NULL,
    description text,
    user_id integer NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT points_in_range CHECK (((points >= (0)::double precision) AND (points <= (points_possible)::double precision))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_grade OWNER TO superuser;

--
-- Name: quiz_grade_distributions; Type: VIEW; Schema: api; Owner: superuser
--

CREATE VIEW api.quiz_grade_distributions AS
 SELECT quiz_grade.quiz_id,
    count(quiz_grade.user_id) AS count,
    avg(quiz_grade.points) AS average,
    min(quiz_grade.points) AS min,
    max(quiz_grade.points) AS max,
    max(quiz_grade.points_possible) AS points_possible,
    stddev_pop(quiz_grade.points) AS stddev,
    array_agg(quiz_grade.points ORDER BY quiz_grade.points) AS grades
   FROM (data.quiz_grade
     JOIN data."user" ON ((quiz_grade.user_id = "user".id)))
  WHERE ("user".role = 'student'::data.user_role)
  GROUP BY quiz_grade.quiz_id
 HAVING (count(quiz_grade.user_id) >= 3);


ALTER VIEW api.quiz_grade_distributions OWNER TO superuser;

--
-- Name: VIEW quiz_grade_distributions; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON VIEW api.quiz_grade_distributions IS 'Statics on the grades received by students for each quiz';


--
-- Name: COLUMN quiz_grade_distributions.quiz_id; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.quiz_id IS 'The slug for the quiz to which these statistics correspond';


--
-- Name: COLUMN quiz_grade_distributions.count; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.count IS 'The number of students with grades for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.average; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.average IS 'The average grade among students for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.min; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.min IS 'The minmum grade among students for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.max; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.max IS 'The maximum grade among students for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.points_possible; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.points_possible IS 'The number of points possible for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.stddev; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.stddev IS 'The standard deviation of student grades for this quiz';


--
-- Name: COLUMN quiz_grade_distributions.grades; Type: COMMENT; Schema: api; Owner: superuser
--

COMMENT ON COLUMN api.quiz_grade_distributions.grades IS 'The grades received by students for this quiz in ascending order';


--
-- Name: quiz_grade_exception; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz_grade_exception (
    id integer NOT NULL,
    quiz_id integer NOT NULL,
    user_id integer NOT NULL,
    fractional_credit numeric DEFAULT 1 NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT quiz_grade_exception_fractional_credit_check CHECK (((fractional_credit >= (0)::numeric) AND (fractional_credit <= (1)::numeric))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_grade_exception OWNER TO superuser;

--
-- Name: quiz_grade_exceptions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_grade_exceptions AS
 SELECT id,
    quiz_id,
    user_id,
    fractional_credit,
    closed_at,
    created_at,
    updated_at
   FROM data.quiz_grade_exception;


ALTER VIEW api.quiz_grade_exceptions OWNER TO api;

--
-- Name: quiz_grades; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_grades AS
 SELECT quiz_id,
    points,
    points_possible,
    description,
    user_id,
    created_at,
    updated_at
   FROM data.quiz_grade;


ALTER VIEW api.quiz_grades OWNER TO api;

--
-- Name: quiz_submission; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz_submission (
    quiz_id integer NOT NULL,
    user_id integer DEFAULT request.user_id() NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz_submission OWNER TO superuser;

--
-- Name: quiz_submissions; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quiz_submissions AS
 SELECT quiz_id,
    user_id,
    created_at,
    updated_at
   FROM data.quiz_submission;


ALTER VIEW api.quiz_submissions OWNER TO api;

--
-- Name: quiz; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.quiz (
    id integer NOT NULL,
    meeting_slug text NOT NULL,
    points_possible smallint NOT NULL,
    is_offline boolean DEFAULT true NOT NULL,
    is_draft boolean DEFAULT true NOT NULL,
    duration interval DEFAULT '00:15:00'::interval NOT NULL,
    open_at timestamp with time zone NOT NULL,
    closed_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT closed_after_open CHECK ((closed_at > open_at)),
    CONSTRAINT quiz_meeting_slug_check CHECK ((char_length(meeting_slug) < 100)),
    CONSTRAINT quiz_points_possible_check CHECK ((points_possible >= 0)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.quiz OWNER TO superuser;

--
-- Name: quizzes; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.quizzes WITH (security_barrier='true') AS
 SELECT id,
    meeting_slug,
    points_possible,
    is_offline,
    is_draft,
    duration,
    open_at,
    closed_at,
    created_at,
    updated_at,
    ((is_draft = false) AND (open_at < CURRENT_TIMESTAMP) AND (CURRENT_TIMESTAMP < closed_at)) AS is_open
   FROM data.quiz
  WHERE ((request.user_role() = 'faculty'::text) OR (quiz.is_draft = false));


ALTER VIEW api.quizzes OWNER TO api;

--
-- Name: team; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.team (
    nickname text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT team_nickname_check CHECK ((char_length(nickname) < 50)),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT valid_team_nickname CHECK ((nickname ~ '^[\w]{2,20}-[\w]{2,20}$'::text))
);


ALTER TABLE data.team OWNER TO superuser;

--
-- Name: teams; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.teams AS
 SELECT nickname,
    created_at,
    updated_at
   FROM data.team;


ALTER VIEW api.teams OWNER TO api;

--
-- Name: ui_element; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.ui_element (
    key text NOT NULL,
    body text,
    is_markdown boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT ui_element_key_check CHECK (((key ~ '^[a-z0-9\-]+$'::text) AND (char_length(key) < 50))),
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at))
);


ALTER TABLE data.ui_element OWNER TO superuser;

--
-- Name: ui_elements; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.ui_elements AS
 SELECT key,
    body,
    is_markdown,
    created_at,
    updated_at
   FROM data.ui_element;


ALTER VIEW api.ui_elements OWNER TO api;

--
-- Name: user_jwts; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.user_jwts AS
 SELECT
        CASE
            WHEN ((role <> 'observer'::data.user_role) AND ((request.user_role() = 'faculty'::text) OR (request.user_id() = id) OR ((request.user_role() = 'app'::text) AND (request.app_name() = 'authapp'::text)))) THEN auth.sign_jwt(id, role)
            ELSE NULL::text
        END AS jwt,
    id,
    email,
    netid,
    name,
    lastname,
    organization,
    known_as,
    nickname,
    role,
    created_at,
    updated_at,
    team_nickname
   FROM data."user";


ALTER VIEW api.user_jwts OWNER TO api;

--
-- Name: user_secret; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.user_secret (
    id integer NOT NULL,
    slug text NOT NULL,
    body text NOT NULL,
    is_user_visible boolean DEFAULT true NOT NULL,
    user_id integer,
    team_nickname text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT updated_after_created CHECK ((updated_at >= created_at)),
    CONSTRAINT user_or_team CHECK ((((team_nickname IS NOT NULL) AND (user_id IS NULL)) OR ((team_nickname IS NULL) AND (user_id IS NOT NULL)))),
    CONSTRAINT user_secret_slug_check CHECK (((slug ~ '^[a-z0-9][a-z0-9_-]+[a-z0-9]$'::text) AND (char_length(slug) < 100))),
    CONSTRAINT user_secret_team_nickname_check CHECK ((char_length(team_nickname) < 50))
);


ALTER TABLE data.user_secret OWNER TO superuser;

--
-- Name: user_secrets; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.user_secrets AS
 SELECT id,
    slug,
    body,
    is_user_visible,
    user_id,
    team_nickname,
    created_at,
    updated_at
   FROM data.user_secret;


ALTER VIEW api.user_secrets OWNER TO api;

--
-- Name: users; Type: VIEW; Schema: api; Owner: api
--

CREATE VIEW api.users AS
 SELECT id,
    email,
    netid,
    name,
    lastname,
    organization,
    known_as,
    nickname,
    role,
    created_at,
    updated_at,
    team_nickname
   FROM data."user";


ALTER VIEW api.users OWNER TO api;

--
-- Name: assignment_grade_exception_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_grade_exception ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.assignment_grade_exception_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: artifact_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.artifact ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.artifact_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: assignment_submission_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_submission ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.assignment_submission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quiz_grade_exception_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_grade_exception ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.quiz_grade_exception_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quiz_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.quiz_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: todo; Type: TABLE; Schema: data; Owner: superuser
--

CREATE TABLE data.todo (
    id integer NOT NULL,
    todo text NOT NULL,
    private boolean DEFAULT true,
    owner_id integer DEFAULT request.user_id()
);


ALTER TABLE data.todo OWNER TO superuser;

--
-- Name: todo_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.todo ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.todo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data."user" ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_secret_id_seq; Type: SEQUENCE; Schema: data; Owner: superuser
--

ALTER TABLE data.user_secret ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME data.user_secret_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: assignment_field assignment_field_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field
    ADD CONSTRAINT assignment_field_pkey PRIMARY KEY (slug, assignment_slug);


--
-- Name: assignment_field assignment_field_slug_assignment_slug_is_url_pattern_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field
    ADD CONSTRAINT assignment_field_slug_assignment_slug_is_url_pattern_key UNIQUE (slug, assignment_slug, is_url, pattern);


--
-- Name: assignment_field_submission assignment_field_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_pkey PRIMARY KEY (assignment_submission_id, assignment_field_slug);


--
-- Name: artifact artifact_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.artifact
    ADD CONSTRAINT artifact_pkey PRIMARY KEY (id);


--
-- Name: artifact artifact_user_slug_unique; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.artifact
    ADD CONSTRAINT artifact_user_slug_unique UNIQUE (user_id, slug);


--
-- Name: assignment_grade_exception assignment_grade_exception_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_pkey PRIMARY KEY (id);


--
-- Name: assignment_grade assignment_grade_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade
    ADD CONSTRAINT assignment_grade_pkey PRIMARY KEY (assignment_submission_id);


--
-- Name: assignment assignment_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment
    ADD CONSTRAINT assignment_pkey PRIMARY KEY (slug);


--
-- Name: assignment assignment_slug_is_team_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment
    ADD CONSTRAINT assignment_slug_is_team_key UNIQUE (slug, is_team);


--
-- Name: assignment assignment_slug_points_possible_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment
    ADD CONSTRAINT assignment_slug_points_possible_key UNIQUE (slug, points_possible);


--
-- Name: assignment_submission assignment_submission_id_assignment_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_id_assignment_slug_key UNIQUE (id, assignment_slug);


--
-- Name: assignment_submission_participant assignment_submission_participant_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission_participant
    ADD CONSTRAINT assignment_submission_participant_pkey PRIMARY KEY (assignment_submission_id, user_id);


--
-- Name: assignment_submission assignment_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_pkey PRIMARY KEY (id);


--
-- Name: engagement engagement_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.engagement
    ADD CONSTRAINT engagement_pkey PRIMARY KEY (user_id, meeting_slug);


--
-- Name: grade_snapshot grade_snapshot_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.grade_snapshot
    ADD CONSTRAINT grade_snapshot_pkey PRIMARY KEY (slug);


--
-- Name: grade grade_snapshot_slug_user_id_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.grade
    ADD CONSTRAINT grade_snapshot_slug_user_id_key UNIQUE (snapshot_slug, user_id);


--
-- Name: meeting meeting_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.meeting
    ADD CONSTRAINT meeting_slug_key UNIQUE (slug);


--
-- Name: quiz_grade_exception quiz_grade_exception_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_pkey PRIMARY KEY (id);


--
-- Name: quiz_grade_exception quiz_grade_exception_quiz_id_user_id_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_quiz_id_user_id_key UNIQUE (quiz_id, user_id);


--
-- Name: quiz_grade quiz_grade_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_pkey PRIMARY KEY (quiz_id, user_id);


--
-- Name: quiz quiz_id_points_possible_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_id_points_possible_key UNIQUE (id, points_possible);


--
-- Name: quiz quiz_meeting_slug_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_meeting_slug_key UNIQUE (meeting_slug);


--
-- Name: quiz quiz_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_pkey PRIMARY KEY (id);


--
-- Name: quiz_submission quiz_submission_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_submission
    ADD CONSTRAINT quiz_submission_pkey PRIMARY KEY (quiz_id, user_id);


--
-- Name: team team_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.team
    ADD CONSTRAINT team_pkey PRIMARY KEY (nickname);


--
-- Name: todo todo_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.todo
    ADD CONSTRAINT todo_pkey PRIMARY KEY (id);


--
-- Name: ui_element ui_element_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.ui_element
    ADD CONSTRAINT ui_element_pkey PRIMARY KEY (key);


--
-- Name: user user_email_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_email_key UNIQUE (email);


--
-- Name: user user_netid_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_netid_key UNIQUE (netid);


--
-- Name: user user_nickname_key; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_nickname_key UNIQUE (nickname);


--
-- Name: user user_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_pkey PRIMARY KEY (id);


--
-- Name: user_secret user_secret_pkey; Type: CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.user_secret
    ADD CONSTRAINT user_secret_pkey PRIMARY KEY (id);


--
-- Name: secrets secrets_pkey; Type: CONSTRAINT; Schema: settings; Owner: superuser
--

ALTER TABLE ONLY settings.secrets
    ADD CONSTRAINT secrets_pkey PRIMARY KEY (key);


--
-- Name: assignment_grade_exception_unique_team; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_grade_exception_unique_team ON data.assignment_grade_exception USING btree (assignment_slug, team_nickname) WHERE (is_team = true);


--
-- Name: assignment_grade_exception_unique_user; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_grade_exception_unique_user ON data.assignment_grade_exception USING btree (assignment_slug, user_id) WHERE (is_team = false);


--
-- Name: assignment_submission_unique_team; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_submission_unique_team ON data.assignment_submission USING btree (team_nickname, assignment_slug) WHERE (user_id IS NULL);


--
-- Name: assignment_submission_unique_user; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX assignment_submission_unique_user ON data.assignment_submission USING btree (user_id, assignment_slug) WHERE (team_nickname IS NULL);


--
-- Name: idx_assignment_field_assignment_slug_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_field_assignment_slug_fk ON data.assignment_field USING btree (assignment_slug);


--
-- Name: idx_assignment_field_submission_field_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_field_submission_field_fk ON data.assignment_field_submission USING btree (assignment_field_slug, assignment_slug, assignment_field_is_url, assignment_field_pattern);


--
-- Name: idx_assignment_field_submission_submission_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_field_submission_submission_fk ON data.assignment_field_submission USING btree (assignment_submission_id, assignment_slug);


--
-- Name: idx_assignment_field_submission_submitter_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_field_submission_submitter_fk ON data.assignment_field_submission USING btree (submitter_user_id);


--
-- Name: idx_artifact_quiz_id_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_artifact_quiz_id_fk ON data.artifact USING btree (quiz_id);


--
-- Name: idx_artifact_user_id_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_artifact_user_id_fk ON data.artifact USING btree (user_id);


--
-- Name: idx_assignment_grade_assignment_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_grade_assignment_fk ON data.assignment_grade USING btree (assignment_slug, points_possible);


--
-- Name: idx_assignment_grade_exception_assignment_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_grade_exception_assignment_fk ON data.assignment_grade_exception USING btree (assignment_slug, is_team);


--
-- Name: idx_assignment_grade_exception_team_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_grade_exception_team_fk ON data.assignment_grade_exception USING btree (team_nickname);


--
-- Name: idx_assignment_grade_exception_user_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_grade_exception_user_fk ON data.assignment_grade_exception USING btree (user_id);


--
-- Name: idx_assignment_grade_submission_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_grade_submission_fk ON data.assignment_grade USING btree (assignment_submission_id, assignment_slug);


--
-- Name: idx_assignment_submission_assignment_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_submission_assignment_fk ON data.assignment_submission USING btree (assignment_slug, is_team);


--
-- Name: idx_assignment_submission_participant_user_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_submission_participant_user_fk ON data.assignment_submission_participant USING btree (user_id);


--
-- Name: idx_assignment_submission_submitter_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_submission_submitter_fk ON data.assignment_submission USING btree (submitter_user_id);


--
-- Name: idx_assignment_submission_team_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_submission_team_fk ON data.assignment_submission USING btree (team_nickname);


--
-- Name: idx_assignment_submission_user_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_assignment_submission_user_fk ON data.assignment_submission USING btree (user_id);


--
-- Name: idx_engagement_meeting_slug_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_engagement_meeting_slug_fk ON data.engagement USING btree (meeting_slug);


--
-- Name: idx_grade_user_id_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_grade_user_id_fk ON data.grade USING btree (user_id);


--
-- Name: idx_quiz_grade_exception_user_id_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_quiz_grade_exception_user_id_fk ON data.quiz_grade_exception USING btree (user_id);


--
-- Name: idx_quiz_grade_quiz_points_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_quiz_grade_quiz_points_fk ON data.quiz_grade USING btree (quiz_id, points_possible);


--
-- Name: idx_quiz_grade_user_id_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_quiz_grade_user_id_fk ON data.quiz_grade USING btree (user_id);


--
-- Name: idx_quiz_submission_user_id_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_quiz_submission_user_id_fk ON data.quiz_submission USING btree (user_id);


--
-- Name: idx_todo_owner_id_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_todo_owner_id_fk ON data.todo USING btree (owner_id);


--
-- Name: idx_user_secret_team_nickname_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_user_secret_team_nickname_fk ON data.user_secret USING btree (team_nickname);


--
-- Name: idx_user_secret_user_id_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_user_secret_user_id_fk ON data.user_secret USING btree (user_id);


--
-- Name: idx_user_team_nickname_fk; Type: INDEX; Schema: data; Owner: superuser
--

CREATE INDEX idx_user_team_nickname_fk ON data."user" USING btree (team_nickname);


--
-- Name: secret_unique_slug_team; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX secret_unique_slug_team ON data.user_secret USING btree (team_nickname, slug) WHERE (user_id IS NULL);


--
-- Name: secret_unique_slug_user; Type: INDEX; Schema: data; Owner: superuser
--

CREATE UNIQUE INDEX secret_unique_slug_user ON data.user_secret USING btree (user_id, slug) WHERE (team_nickname IS NULL);


--
-- Name: assignment tg_assignment_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_default BEFORE INSERT OR UPDATE ON data.assignment FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: assignment_field tg_assignment_field_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_field_default BEFORE INSERT OR UPDATE ON data.assignment_field FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: assignment_field_submission tg_assignment_field_submission_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_field_submission_default BEFORE INSERT OR UPDATE ON data.assignment_field_submission FOR EACH ROW EXECUTE FUNCTION data.fill_assignment_field_submission_defaults();


--
-- Name: assignment_grade tg_assignment_grade_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_grade_default BEFORE INSERT OR UPDATE ON data.assignment_grade FOR EACH ROW EXECUTE FUNCTION data.fill_assignment_grade_defaults();


--
-- Name: assignment_grade_exception tg_assignment_grade_exception_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_grade_exception_default BEFORE INSERT OR UPDATE ON data.assignment_grade_exception FOR EACH ROW EXECUTE FUNCTION data.fill_assignment_grade_exception_defaults();


--
-- Name: assignment_submission tg_assignment_submission_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_submission_default BEFORE INSERT OR UPDATE ON data.assignment_submission FOR EACH ROW EXECUTE FUNCTION data.fill_assignment_submission_defaults();


--
-- Name: assignment_submission tg_assignment_submission_participants; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_assignment_submission_participants AFTER INSERT ON data.assignment_submission FOR EACH ROW EXECUTE FUNCTION data.refresh_assignment_submission_participants();


--
-- Name: artifact tg_artifact_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_artifact_default BEFORE INSERT OR UPDATE ON data.artifact FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: engagement tg_engagement_update_timestamps; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_engagement_update_timestamps BEFORE INSERT OR UPDATE ON data.engagement FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: grade tg_grade_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_grade_default BEFORE INSERT OR UPDATE ON data.grade FOR EACH ROW EXECUTE FUNCTION data.fill_grade_defaults();


--
-- Name: grade_snapshot tg_grade_snapshot_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_grade_snapshot_default BEFORE INSERT OR UPDATE ON data.grade_snapshot FOR EACH ROW EXECUTE FUNCTION data.fill_grade_snapshot_defaults();


--
-- Name: meeting tg_meeting_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_meeting_default BEFORE INSERT OR UPDATE ON data.meeting FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: quiz tg_quiz_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_default BEFORE INSERT OR UPDATE ON data.quiz FOR EACH ROW EXECUTE FUNCTION data.quiz_set_defaults();


--
-- Name: quiz_grade tg_quiz_grade_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_grade_default BEFORE INSERT OR UPDATE ON data.quiz_grade FOR EACH ROW EXECUTE FUNCTION data.fill_quiz_grade_defaults();


--
-- Name: quiz_grade_exception tg_quiz_grade_exception_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_grade_exception_default BEFORE INSERT OR UPDATE ON data.quiz_grade_exception FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: quiz_submission tg_quiz_submission_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_quiz_submission_default BEFORE INSERT OR UPDATE ON data.quiz_submission FOR EACH ROW EXECUTE FUNCTION data.fill_quiz_submission_defaults();


--
-- Name: team tg_team_update_timestamps; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_team_update_timestamps BEFORE INSERT OR UPDATE ON data.team FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: ui_element tg_ui_element_update_timestamps; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_ui_element_update_timestamps BEFORE INSERT OR UPDATE ON data.ui_element FOR EACH ROW EXECUTE FUNCTION data.update_updated_at_column();


--
-- Name: user_secret tg_user_secret_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_user_secret_default BEFORE INSERT OR UPDATE ON data.user_secret FOR EACH ROW EXECUTE FUNCTION data.fill_user_secret_defaults();


--
-- Name: user tg_users_default; Type: TRIGGER; Schema: data; Owner: superuser
--

CREATE TRIGGER tg_users_default BEFORE INSERT OR UPDATE ON data."user" FOR EACH ROW EXECUTE FUNCTION data.clean_user_fields();


--
-- Name: assignment_field assignment_field_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field
    ADD CONSTRAINT assignment_field_assignment_slug_fkey FOREIGN KEY (assignment_slug) REFERENCES data.assignment(slug) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_assignment_field_slug_assignme_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_assignment_field_slug_assignme_fkey FOREIGN KEY (assignment_field_slug, assignment_slug, assignment_field_is_url, assignment_field_pattern) REFERENCES data.assignment_field(slug, assignment_slug, is_url, pattern) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_assignment_submission_id_assig_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_assignment_submission_id_assig_fkey FOREIGN KEY (assignment_submission_id, assignment_slug) REFERENCES data.assignment_submission(id, assignment_slug) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission assignment_field_submission_submitter_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_field_submission
    ADD CONSTRAINT assignment_field_submission_submitter_user_id_fkey FOREIGN KEY (submitter_user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_grade assignment_grade_assignment_slug_points_possible_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade
    ADD CONSTRAINT assignment_grade_assignment_slug_points_possible_fkey FOREIGN KEY (assignment_slug, points_possible) REFERENCES data.assignment(slug, points_possible) ON UPDATE CASCADE;


--
-- Name: assignment_grade assignment_grade_assignment_submission_id_assignment_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade
    ADD CONSTRAINT assignment_grade_assignment_submission_id_assignment_slug_fkey FOREIGN KEY (assignment_submission_id, assignment_slug) REFERENCES data.assignment_submission(id, assignment_slug) ON UPDATE CASCADE;


--
-- Name: assignment_grade_exception assignment_grade_exception_assignment_slug_is_team_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_assignment_slug_is_team_fkey FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment(slug, is_team) ON UPDATE CASCADE;


--
-- Name: assignment_grade_exception assignment_grade_exception_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: assignment_grade_exception assignment_grade_exception_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_grade_exception
    ADD CONSTRAINT assignment_grade_exception_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_assignment_slug_is_team_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_assignment_slug_is_team_fkey FOREIGN KEY (assignment_slug, is_team) REFERENCES data.assignment(slug, is_team) ON UPDATE CASCADE;


--
-- Name: assignment_submission_participant assignment_submission_participant_assignment_submission_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission_participant
    ADD CONSTRAINT assignment_submission_participant_assignment_submission_id_fkey FOREIGN KEY (assignment_submission_id) REFERENCES data.assignment_submission(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assignment_submission_participant assignment_submission_participant_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission_participant
    ADD CONSTRAINT assignment_submission_participant_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_submitter_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_submitter_user_id_fkey FOREIGN KEY (submitter_user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: assignment_submission assignment_submission_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.assignment_submission
    ADD CONSTRAINT assignment_submission_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: artifact artifact_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.artifact
    ADD CONSTRAINT artifact_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: artifact artifact_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.artifact
    ADD CONSTRAINT artifact_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: engagement engagement_meeting_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.engagement
    ADD CONSTRAINT engagement_meeting_slug_fkey FOREIGN KEY (meeting_slug) REFERENCES data.meeting(slug) ON UPDATE CASCADE;


--
-- Name: engagement engagement_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.engagement
    ADD CONSTRAINT engagement_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: grade grade_snapshot_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.grade
    ADD CONSTRAINT grade_snapshot_slug_fkey FOREIGN KEY (snapshot_slug) REFERENCES data.grade_snapshot(slug) ON UPDATE CASCADE;


--
-- Name: grade grade_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.grade
    ADD CONSTRAINT grade_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: quiz_grade_exception quiz_grade_exception_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE;


--
-- Name: quiz_grade_exception quiz_grade_exception_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade_exception
    ADD CONSTRAINT quiz_grade_exception_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: quiz_grade quiz_grade_quiz_id_points_possible_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_quiz_id_points_possible_fkey FOREIGN KEY (quiz_id, points_possible) REFERENCES data.quiz(id, points_possible) ON UPDATE CASCADE;


--
-- Name: quiz_grade quiz_grade_quiz_id_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_quiz_id_user_id_fkey FOREIGN KEY (quiz_id, user_id) REFERENCES data.quiz_submission(quiz_id, user_id) ON UPDATE CASCADE;


--
-- Name: quiz_grade quiz_grade_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_grade
    ADD CONSTRAINT quiz_grade_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: quiz quiz_meeting_slug_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz
    ADD CONSTRAINT quiz_meeting_slug_fkey FOREIGN KEY (meeting_slug) REFERENCES data.meeting(slug) ON UPDATE CASCADE;


--
-- Name: quiz_submission quiz_submission_quiz_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_submission
    ADD CONSTRAINT quiz_submission_quiz_id_fkey FOREIGN KEY (quiz_id) REFERENCES data.quiz(id) ON UPDATE CASCADE;


--
-- Name: quiz_submission quiz_submission_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.quiz_submission
    ADD CONSTRAINT quiz_submission_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: todo todo_owner_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.todo
    ADD CONSTRAINT todo_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES data."user"(id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user_secret user_secret_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.user_secret
    ADD CONSTRAINT user_secret_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: user_secret user_secret_user_id_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data.user_secret
    ADD CONSTRAINT user_secret_user_id_fkey FOREIGN KEY (user_id) REFERENCES data."user"(id) ON UPDATE CASCADE;


--
-- Name: user user_team_nickname_fkey; Type: FK CONSTRAINT; Schema: data; Owner: superuser
--

ALTER TABLE ONLY data."user"
    ADD CONSTRAINT user_team_nickname_fkey FOREIGN KEY (team_nickname) REFERENCES data.team(nickname) ON UPDATE CASCADE;


--
-- Name: assignment_field_submission; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_field_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_field_submission assignment_field_submission_delete_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_field_submission_delete_policy ON data.assignment_field_submission FOR DELETE TO api USING ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_field_submission assignment_field_submission_insert_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_field_submission_insert_policy ON data.assignment_field_submission FOR INSERT TO api WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND (submitter_user_id = request.user_id()) AND data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id))));


--
-- Name: assignment_field_submission assignment_field_submission_select_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_field_submission_select_policy ON data.assignment_field_submission FOR SELECT TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND ((submitter_user_id = request.user_id()) OR (EXISTS ( SELECT ass_sub.id
   FROM api.assignment_submissions ass_sub
  WHERE (ass_sub.id = assignment_field_submission.assignment_submission_id))) OR data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id))) OR (request.user_role() = 'faculty'::text)));


--
-- Name: assignment_field_submission assignment_field_submission_update_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_field_submission_update_policy ON data.assignment_field_submission FOR UPDATE TO api USING (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND ((submitter_user_id = request.user_id()) OR data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id))))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND (submitter_user_id = request.user_id()) AND data.assignment_field_submission_is_writable_by_current_user(assignment_submission_id))));


--
-- Name: assignment_grade; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_grade ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_grade assignment_grade_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_grade_access_policy ON data.assignment_grade TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (EXISTS ( SELECT ass_sub.id
   FROM api.assignment_submissions ass_sub
  WHERE (assignment_grade.assignment_submission_id = ass_sub.id)))) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_grade_exception; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_grade_exception ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_grade_exception assignment_grade_exception_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_grade_exception_access_policy ON data.assignment_grade_exception TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND ((((NOT is_team) AND (request.user_id() = user_id))) OR (is_team AND (EXISTS ( SELECT u.id
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND (u.team_nickname = assignment_grade_exception.team_nickname))))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: artifact; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.artifact ENABLE ROW LEVEL SECURITY;

--
-- Name: artifact artifact_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY artifact_access_policy ON data.artifact TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND is_user_visible AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: assignment_submission; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.assignment_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: assignment_submission assignment_submission_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY assignment_submission_access_policy ON data.assignment_submission TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (((request.user_id() = submitter_user_id) AND (NOT (EXISTS ( SELECT 1
   FROM data.assignment_submission_participant p
  WHERE (p.assignment_submission_id = assignment_submission.id))))) OR (EXISTS ( SELECT p.user_id
   FROM data.assignment_submission_participant p
  WHERE ((p.assignment_submission_id = assignment_submission.id) AND (p.user_id = request.user_id())))))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK (((request.user_role() = 'faculty'::text) OR ((request.user_role() = ANY ('{student,ta}'::text[])) AND (EXISTS ( SELECT a.slug
   FROM ((api.assignments a
     LEFT JOIN api.assignment_grade_exceptions e ON ((a.slug = e.assignment_slug)))
     LEFT JOIN api.users u ON (((e.user_id = u.id) OR (e.team_nickname = u.team_nickname))))
  WHERE ((a.slug = assignment_submission.assignment_slug) AND (a.is_open OR ((e.closed_at > CURRENT_TIMESTAMP) AND (a.is_draft = false) AND ((e.user_id = assignment_submission.user_id) OR (e.team_nickname = assignment_submission.team_nickname))))))) AND (((NOT is_team) AND (request.user_id() = user_id)) OR (is_team AND (EXISTS ( SELECT u.id
   FROM data."user" u
  WHERE ((u.id = request.user_id()) AND (u.team_nickname = assignment_submission.team_nickname)))))))));


--
-- Name: engagement; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.engagement ENABLE ROW LEVEL SECURITY;

--
-- Name: engagement engagement_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY engagement_access_policy ON data.engagement TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = user_id)) OR (request.user_role() = ANY ('{faculty,ta}'::text[]))));


--
-- Name: grade; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.grade ENABLE ROW LEVEL SECURITY;

--
-- Name: grade grade_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY grade_access_policy ON data.grade TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_grade; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_grade ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_grade quiz_grade_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_grade_access_policy ON data.quiz_grade TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_grade_exception; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_grade_exception ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_grade_exception quiz_grade_exception_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_grade_exception_access_policy ON data.quiz_grade_exception TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: quiz_submission; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.quiz_submission ENABLE ROW LEVEL SECURITY;

--
-- Name: quiz_submission quiz_submission_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY quiz_submission_access_policy ON data.quiz_submission TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (request.user_id() = user_id)) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: team; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.team ENABLE ROW LEVEL SECURITY;

--
-- Name: team team_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY team_access_policy ON data.team TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND (nickname = ( SELECT users.team_nickname
   FROM api.users
  WHERE (users.id = request.user_id())))) OR (request.user_role() = 'faculty'::text)));


--
-- Name: user; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data."user" ENABLE ROW LEVEL SECURITY;

--
-- Name: user user_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY user_access_policy ON data."user" TO api USING ((((request.user_role() = 'student'::text) AND (request.user_id() = id)) OR (request.user_role() = ANY ('{faculty,ta}'::text[])) OR ((request.user_role() = 'app'::text) AND (request.app_name() = 'authapp'::text))));


--
-- Name: user_secret; Type: ROW SECURITY; Schema: data; Owner: superuser
--

ALTER TABLE data.user_secret ENABLE ROW LEVEL SECURITY;

--
-- Name: user_secret user_secret_access_policy; Type: POLICY; Schema: data; Owner: superuser
--

CREATE POLICY user_secret_access_policy ON data.user_secret TO api USING ((((request.user_role() = ANY ('{student,ta}'::text[])) AND is_user_visible AND ((request.user_id() = user_id) OR (EXISTS ( SELECT u.id
   FROM api.users u
  WHERE ((u.id = request.user_id()) AND (u.team_nickname = user_secret.team_nickname)))))) OR (request.user_role() = 'faculty'::text))) WITH CHECK ((request.user_role() = 'faculty'::text));


--
-- Name: SCHEMA api; Type: ACL; Schema: -; Owner: superuser
--

GRANT USAGE ON SCHEMA api TO anonymous;
GRANT USAGE ON SCHEMA api TO student;
GRANT USAGE ON SCHEMA api TO ta;
GRANT USAGE ON SCHEMA api TO faculty;
GRANT USAGE ON SCHEMA api TO app;


--
-- Name: SCHEMA data; Type: ACL; Schema: -; Owner: superuser
--

GRANT USAGE ON SCHEMA data TO ta;
GRANT USAGE ON SCHEMA data TO faculty;


--
-- Name: SCHEMA request; Type: ACL; Schema: -; Owner: superuser
--

GRANT USAGE ON SCHEMA request TO PUBLIC;


--
-- Name: FUNCTION sync_assignments(p_assignments jsonb, p_delete_missing boolean, p_dry_run boolean); Type: ACL; Schema: api; Owner: superuser
--

REVOKE ALL ON FUNCTION api.sync_assignments(p_assignments jsonb, p_delete_missing boolean, p_dry_run boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_assignments(p_assignments jsonb, p_delete_missing boolean, p_dry_run boolean) TO faculty;


--
-- Name: FUNCTION sync_meetings(p_meetings jsonb); Type: ACL; Schema: api; Owner: superuser
--

REVOKE ALL ON FUNCTION api.sync_meetings(p_meetings jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION api.sync_meetings(p_meetings jsonb) TO faculty;


--
-- Name: FUNCTION sign_jwt(user_id integer, role data.user_role); Type: ACL; Schema: auth; Owner: superuser
--

REVOKE ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) FROM PUBLIC;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO api;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO student;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO ta;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO faculty;
GRANT ALL ON FUNCTION auth.sign_jwt(user_id integer, role data.user_role) TO app;


--
-- Name: TABLE assignment_field_submission; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_field_submission TO api;


--
-- Name: TABLE assignment_field_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT,UPDATE ON TABLE api.assignment_field_submissions TO student;
GRANT SELECT,INSERT,UPDATE ON TABLE api.assignment_field_submissions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_field_submissions TO faculty;


--
-- Name: TABLE artifact; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.artifact TO api;


--
-- Name: TABLE artifacts; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.artifacts TO student;
GRANT SELECT ON TABLE api.artifacts TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.artifacts TO faculty;


--
-- Name: TABLE assignment_field; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_field TO api;


--
-- Name: TABLE assignment_fields; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_fields TO student;
GRANT SELECT ON TABLE api.assignment_fields TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_fields TO faculty;


--
-- Name: TABLE assignment_grade; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_grade TO api;


--
-- Name: TABLE assignment_submission; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_submission TO api;


--
-- Name: TABLE assignment_submission_participant; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_submission_participant TO api;


--
-- Name: TABLE "user"; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data."user" TO api;


--
-- Name: TABLE assignment_grade_distributions; Type: ACL; Schema: api; Owner: superuser
--

GRANT SELECT ON TABLE api.assignment_grade_distributions TO student;
GRANT SELECT ON TABLE api.assignment_grade_distributions TO ta;
GRANT SELECT ON TABLE api.assignment_grade_distributions TO faculty;


--
-- Name: TABLE assignment_grade_exception; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment_grade_exception TO api;


--
-- Name: TABLE assignment_grade_exceptions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_grade_exceptions TO student;
GRANT SELECT ON TABLE api.assignment_grade_exceptions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_grade_exceptions TO faculty;


--
-- Name: TABLE assignment_grades; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignment_grades TO student;
GRANT SELECT ON TABLE api.assignment_grades TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_grades TO faculty;


--
-- Name: TABLE assignment_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT,INSERT ON TABLE api.assignment_submissions TO student;
GRANT SELECT,INSERT ON TABLE api.assignment_submissions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignment_submissions TO faculty;


--
-- Name: TABLE assignment; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.assignment TO api;


--
-- Name: TABLE assignments; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.assignments TO student;
GRANT SELECT ON TABLE api.assignments TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.assignments TO faculty;


--
-- Name: TABLE engagement; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.engagement TO api;


--
-- Name: TABLE engagements; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.engagements TO student;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.engagements TO faculty;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.engagements TO ta;


--
-- Name: TABLE grade_snapshot; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.grade_snapshot TO api;


--
-- Name: TABLE grade_snapshots; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.grade_snapshots TO student;
GRANT SELECT ON TABLE api.grade_snapshots TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.grade_snapshots TO faculty;


--
-- Name: TABLE grade; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.grade TO api;


--
-- Name: TABLE grades; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.grades TO student;
GRANT SELECT ON TABLE api.grades TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.grades TO faculty;


--
-- Name: TABLE meeting; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.meeting TO api;


--
-- Name: TABLE meetings; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.meetings TO student;
GRANT SELECT ON TABLE api.meetings TO ta;
GRANT SELECT ON TABLE api.meetings TO anonymous;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.meetings TO faculty;


--
-- Name: TABLE platform_version; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.platform_version TO anonymous;
GRANT SELECT ON TABLE api.platform_version TO student;
GRANT SELECT ON TABLE api.platform_version TO ta;
GRANT SELECT ON TABLE api.platform_version TO faculty;
GRANT SELECT ON TABLE api.platform_version TO app;


--
-- Name: TABLE quiz_grade; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_grade TO api;


--
-- Name: TABLE quiz_grade_distributions; Type: ACL; Schema: api; Owner: superuser
--

GRANT SELECT ON TABLE api.quiz_grade_distributions TO student;
GRANT SELECT ON TABLE api.quiz_grade_distributions TO ta;
GRANT SELECT ON TABLE api.quiz_grade_distributions TO faculty;


--
-- Name: TABLE quiz_grade_exception; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_grade_exception TO api;


--
-- Name: TABLE quiz_grade_exceptions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_grade_exceptions TO student;
GRANT SELECT ON TABLE api.quiz_grade_exceptions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_grade_exceptions TO faculty;


--
-- Name: TABLE quiz_grades; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_grades TO student;
GRANT SELECT ON TABLE api.quiz_grades TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_grades TO faculty;


--
-- Name: TABLE quiz_submission; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz_submission TO api;


--
-- Name: TABLE quiz_submissions; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quiz_submissions TO student;
GRANT SELECT ON TABLE api.quiz_submissions TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quiz_submissions TO faculty;


--
-- Name: TABLE quiz; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.quiz TO api;


--
-- Name: TABLE quizzes; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.quizzes TO student;
GRANT SELECT ON TABLE api.quizzes TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.quizzes TO faculty;


--
-- Name: TABLE team; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.team TO api;


--
-- Name: TABLE teams; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.teams TO student;
GRANT SELECT ON TABLE api.teams TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.teams TO faculty;


--
-- Name: TABLE ui_element; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.ui_element TO api;


--
-- Name: TABLE ui_elements; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.ui_elements TO student;
GRANT SELECT ON TABLE api.ui_elements TO ta;
GRANT SELECT ON TABLE api.ui_elements TO anonymous;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.ui_elements TO faculty;


--
-- Name: TABLE user_jwts; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.user_jwts TO student;
GRANT SELECT ON TABLE api.user_jwts TO ta;
GRANT SELECT ON TABLE api.user_jwts TO faculty;
GRANT SELECT ON TABLE api.user_jwts TO app;


--
-- Name: TABLE user_secret; Type: ACL; Schema: data; Owner: superuser
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE data.user_secret TO api;


--
-- Name: TABLE user_secrets; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.user_secrets TO student;
GRANT SELECT ON TABLE api.user_secrets TO ta;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.user_secrets TO faculty;


--
-- Name: TABLE users; Type: ACL; Schema: api; Owner: api
--

GRANT SELECT ON TABLE api.users TO student;
GRANT SELECT ON TABLE api.users TO ta;
GRANT SELECT ON TABLE api.users TO app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE api.users TO faculty;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: -; Owner: api
--

ALTER DEFAULT PRIVILEGES FOR ROLE api REVOKE ALL ON FUNCTIONS FROM PUBLIC;


--
-- PostgreSQL database dump complete
--

COMMIT;
