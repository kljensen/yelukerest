-- Online quiz question/answer helper functions were removed with the
-- paper-only quiz workflow.

CREATE OR REPLACE FUNCTION sync_meetings(p_meetings jsonb)
RETURNS TABLE (
    inserted_count integer,
    updated_count integer,
    deleted_count integer
)
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
        FROM input_meetings input_meeting
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

REVOKE ALL ON FUNCTION sync_meetings(jsonb) FROM PUBLIC;
