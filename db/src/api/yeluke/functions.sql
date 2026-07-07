-- Online quiz question/answer helper functions were removed with the
-- paper-only quiz workflow.

DROP FUNCTION IF EXISTS sync_meetings(jsonb);
CREATE OR REPLACE FUNCTION sync_meetings(p_meetings jsonb)
RETURNS TABLE (
    inserted_count integer,
    updated_count integer,
    unchanged_count integer,
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

REVOKE ALL ON FUNCTION sync_meetings(jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION sync_assignments(
    p_assignments jsonb,
    p_delete_missing boolean DEFAULT false,
    p_dry_run boolean DEFAULT false
)
RETURNS TABLE (
    inserted_count integer,
    updated_count integer,
    unchanged_count integer,
    deleted_count integer,
    field_inserted_count integer,
    field_updated_count integer,
    field_unchanged_count integer,
    field_deleted_count integer,
    dry_run boolean
)
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

REVOKE ALL ON FUNCTION sync_assignments(jsonb, boolean, boolean) FROM PUBLIC;
