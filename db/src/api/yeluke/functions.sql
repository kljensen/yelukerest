-- Online quiz question/answer helper functions were removed with the
-- paper-only quiz workflow.

CREATE OR REPLACE FUNCTION check_request_jwt() RETURNS void
STABLE
SECURITY DEFINER
LANGUAGE plpgsql
SET search_path = pg_catalog, api, settings, request, pg_temp
AS $$
DECLARE
    claims jsonb;
    claim_role text;
    claim_issuer text;
    expected_audience text;
    expected_subject text;
    audience_claim jsonb;
    audience_text text;
    subject_claim text;
BEGIN
    claim_role := request.user_role();
    IF claim_role IS NULL OR claim_role = '' OR claim_role = 'anonymous' THEN
        RETURN;
    END IF;

    claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
    claim_issuer := request.jwt_claim('iss');
    IF claim_issuer IS DISTINCT FROM settings.get('jwt_issuer') THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt issuer';
    END IF;

    expected_audience := settings.get('jwt_audience');
    audience_claim := CASE WHEN claims IS NULL THEN NULL ELSE claims->'aud' END;
    audience_text := request.jwt_claim('aud');
    IF NOT (
        (jsonb_typeof(audience_claim) = 'string' AND audience_claim #>> '{}' = expected_audience)
        OR
        (jsonb_typeof(audience_claim) = 'array' AND audience_claim ? expected_audience)
        OR
        audience_text = expected_audience
    ) THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt audience';
    END IF;

    subject_claim := request.jwt_claim('sub');
    IF coalesce(subject_claim, '') = '' THEN
        RAISE insufficient_privilege USING MESSAGE = 'missing jwt subject';
    END IF;

    expected_subject := CASE
        WHEN claim_role = 'app' THEN 'app:' || coalesce(request.app_name(), '')
        ELSE 'user:' || coalesce(request.user_id_as_text(), '')
    END;
    IF subject_claim IS DISTINCT FROM expected_subject THEN
        RAISE insufficient_privilege USING MESSAGE = 'invalid jwt subject';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION check_request_jwt() FROM PUBLIC;

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

    IF octet_length(p_meetings::text) > 4194304 THEN
        RAISE EXCEPTION 'sync_meetings payload exceeds the 4 MB limit'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_meetings);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'sync_meetings refuses to sync an empty meeting list'
            USING ERRCODE = '22023';
    END IF;

    IF input_count > 500 THEN
        RAISE EXCEPTION 'sync_meetings accepts at most 500 meetings, received %', input_count
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
        meeting_type data.meeting_type_enum,
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
            meeting_type data.meeting_type_enum,
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
            meeting_type data.meeting_type_enum,
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
            existing_meeting.meeting_type,
            existing_meeting.is_draft
        ) IS DISTINCT FROM (
            input_meeting.title,
            input_meeting.summary,
            input_meeting.description,
            input_meeting.begins_at,
            input_meeting.duration,
            COALESCE(input_meeting.meeting_type, 'lecture'::data.meeting_type_enum),
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
            meeting_type data.meeting_type_enum,
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
            existing_meeting.meeting_type,
            existing_meeting.is_draft
        ) IS DISTINCT FROM (
            input_meeting.title,
            input_meeting.summary,
            input_meeting.description,
            input_meeting.begins_at,
            input_meeting.duration,
            COALESCE(input_meeting.meeting_type, 'lecture'::data.meeting_type_enum),
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
            meeting_type = COALESCE(input_meeting.meeting_type, 'lecture'::data.meeting_type_enum),
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
            meeting_type data.meeting_type_enum,
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
            meeting_type,
            is_draft
        )
        SELECT
            input_meeting.slug,
            input_meeting.title,
            input_meeting.summary,
            input_meeting.description,
            input_meeting.begins_at,
            input_meeting.duration,
            COALESCE(input_meeting.meeting_type, 'lecture'::data.meeting_type_enum),
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
    oversized_fields_assignment_slug text;
    duplicate_field_key text;
BEGIN
    p_delete_missing := COALESCE(p_delete_missing, false);
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;

    IF p_assignments IS NULL OR jsonb_typeof(p_assignments) <> 'array' THEN
        RAISE EXCEPTION 'sync_assignments expects a JSON array'
            USING ERRCODE = '22023';
    END IF;

    IF octet_length(p_assignments::text) > 8388608 THEN
        RAISE EXCEPTION 'sync_assignments payload exceeds the 8 MB limit'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_assignments);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'sync_assignments refuses to sync an empty assignment list'
            USING ERRCODE = '22023';
    END IF;

    IF input_count > 500 THEN
        RAISE EXCEPTION 'sync_assignments accepts at most 500 assignments, received %', input_count
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

    SELECT COALESCE(assignment.value->>'slug', '<missing slug>') INTO oversized_fields_assignment_slug
    FROM jsonb_array_elements(p_assignments) AS assignment(value)
    WHERE jsonb_array_length(assignment.value->'fields') > 50
    LIMIT 1;

    IF oversized_fields_assignment_slug IS NOT NULL THEN
        RAISE EXCEPTION 'sync_assignments accepts at most 50 fields per assignment, exceeded for assignment: %', oversized_fields_assignment_slug
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

-- Resolve import rows to the submission each grade belongs on.
--
-- This lives in the data schema because PostgREST exposes only the api schema
-- and this is not an endpoint, but it is defined here because it reads the api
-- views. It is SECURITY INVOKER on purpose: the caller's own row visibility
-- applies, and a caller who cannot see a submission cannot grade it.
CREATE OR REPLACE FUNCTION data.resolve_assignment_grade_import(p_grades jsonb)
RETURNS TABLE (
    assignment_slug text,
    netid text,
    user_id integer,
    is_team boolean,
    team_nickname text,
    points_possible smallint,
    points real,
    has_description boolean,
    description text,
    assignment_submission_id integer
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        assignment.slug,
        student.netid,
        student.id,
        assignment.is_team,
        student.team_nickname,
        assignment.points_possible,
        (element.value->>'points')::real,
        element.value ? 'description',
        element.value->>'description',
        CASE
            WHEN assignment.is_team THEN team_submission.assignment_submission_id
            ELSE individual_submission.id
        END
    FROM jsonb_array_elements(p_grades) AS element(value)
    JOIN api.assignments assignment
        ON assignment.slug = btrim(element.value->>'assignment_slug')
    JOIN api.users student
        ON student.netid = lower(btrim(element.value->>'netid'))
    -- An individual submission belongs to exactly one student, so the student
    -- identifies it.
    LEFT JOIN api.assignment_submissions individual_submission
        ON NOT assignment.is_team
        AND individual_submission.assignment_slug = assignment.slug
        AND individual_submission.user_id = student.id
    -- A team submission is found through the insert-time participant snapshot,
    -- never through the student's current team. Rosters change mid-term, and a
    -- student who moved teams must still be graded on the work they did rather
    -- than on their new team's work. data.assignment_submission_participant is
    -- the only record of which is which.
    LEFT JOIN data.team_submission_participation team_submission
        ON assignment.is_team
        AND team_submission.assignment_slug = assignment.slug
        AND team_submission.user_id = student.id;
$$;

REVOKE ALL ON FUNCTION data.resolve_assignment_grade_import(jsonb) FROM PUBLIC;

-- Import final assignment grades keyed on assignment_slug + netid.
--
-- The payload carries final, absolute points. This function never derives a
-- curve denominator from the payload: a batch-relative maximum makes the same
-- raw score mean different things depending on which rows happened to be in the
-- file, and a makeup exam sat by a single student would score 100% by
-- construction. Curving belongs to the client, which knows the full cohort.
--
-- Everything is re-runnable. A second run of the same payload writes nothing
-- and reports every row as unchanged, so no redundant 'corrected' rows land in
-- data.assignment_grade_event.
CREATE OR REPLACE FUNCTION import_assignment_grades(
    p_grades jsonb,
    p_create_missing_submissions boolean DEFAULT true,
    p_dry_run boolean DEFAULT false,
    p_import_id text DEFAULT NULL,
    p_reason text DEFAULT NULL
)
RETURNS TABLE (
    inserted_count integer,
    updated_count integer,
    unchanged_count integer,
    submission_created_count integer,
    import_id text,
    dry_run boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    input_count integer;
    description_limit integer;
    offenders text;
BEGIN
    p_create_missing_submissions := COALESCE(p_create_missing_submissions, true);
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;
    import_id := COALESCE(nullif(btrim(p_import_id), ''), gen_random_uuid()::text);

    IF p_grades IS NULL OR jsonb_typeof(p_grades) <> 'array' THEN
        RAISE EXCEPTION 'import_assignment_grades expects a JSON array'
            USING ERRCODE = '22023';
    END IF;

    IF octet_length(p_grades::text) > 4194304 THEN
        RAISE EXCEPTION 'import_assignment_grades payload exceeds the 4 MB limit'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_grades);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'import_assignment_grades refuses to import an empty grade list'
            USING ERRCODE = '22023';
    END IF;

    IF input_count > 2000 THEN
        RAISE EXCEPTION 'import_assignment_grades accepts at most 2000 grades, received %', input_count
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_grades) AS element(value)
        WHERE jsonb_typeof(element.value) <> 'object'
    ) THEN
        RAISE EXCEPTION 'import_assignment_grades expects a JSON object for every grade'
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(position::text, ', ' ORDER BY position) INTO offenders
    FROM (
        SELECT element.position
        FROM jsonb_array_elements(p_grades)
            WITH ORDINALITY AS element(value, position)
        WHERE COALESCE(btrim(element.value->>'assignment_slug'), '') = ''
            OR COALESCE(btrim(element.value->>'netid'), '') = ''
    ) AS incomplete_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires assignment_slug and netid on every grade, missing at position: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- A missing score is not a zero. The CSV loader this replaces dropped such
    -- rows silently; refusing them makes the caller say which one they meant.
    SELECT string_agg(grade_key, ', ' ORDER BY grade_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'assignment_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS grade_key
        FROM jsonb_array_elements(p_grades) AS element(value)
        WHERE element.value->'points' IS NULL
            OR jsonb_typeof(element.value->'points') = 'null'
    ) AS scoreless_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires a points value on every grade, a missing or null score is not a zero: %', offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(grade_key, ', ' ORDER BY grade_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'assignment_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS grade_key
        FROM jsonb_array_elements(p_grades) AS element(value)
        WHERE jsonb_typeof(element.value->'points') <> 'number'
    ) AS non_numeric_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires numeric points: %', offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(grade_key, ', ' ORDER BY grade_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'assignment_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS grade_key
        FROM jsonb_array_elements(p_grades) AS element(value)
        GROUP BY 1
        HAVING count(*) > 1
    ) AS duplicate_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades received duplicate assignment_slug/netid key: %', offenders
            USING ERRCODE = '23505';
    END IF;

    SELECT string_agg(DISTINCT input_grade.assignment_slug, ', '
        ORDER BY input_grade.assignment_slug) INTO offenders
    FROM (
        SELECT btrim(element.value->>'assignment_slug') AS assignment_slug
        FROM jsonb_array_elements(p_grades) AS element(value)
    ) AS input_grade
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.assignments assignment
        WHERE assignment.slug = input_grade.assignment_slug
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades does not know assignment slug: %', offenders
            USING ERRCODE = '23503';
    END IF;

    -- The loader this replaces joined netids to users, so an unknown netid
    -- vanished and the run still reported success.
    SELECT string_agg(DISTINCT input_grade.netid, ', '
        ORDER BY input_grade.netid) INTO offenders
    FROM (
        SELECT lower(btrim(element.value->>'netid')) AS netid
        FROM jsonb_array_elements(p_grades) AS element(value)
    ) AS input_grade
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.users student
        WHERE student.netid = input_grade.netid
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades does not know netid: %', offenders
            USING ERRCODE = '23503';
    END IF;

    -- A student who moved teams mid-term can hold a participant row in two team
    -- submissions for one assignment. Which one the grade belongs to is a
    -- judgement no import can make, so say so rather than pick.
    SELECT string_agg(grade_key, ', ' ORDER BY grade_key) INTO offenders
    FROM (
        SELECT assignment.slug || '/' || student.netid AS grade_key
        FROM jsonb_array_elements(p_grades) AS element(value)
        JOIN api.assignments assignment
            ON assignment.slug = btrim(element.value->>'assignment_slug')
        JOIN api.users student
            ON student.netid = lower(btrim(element.value->>'netid'))
        JOIN data.team_submission_participation participation
            ON participation.assignment_slug = assignment.slug
            AND participation.user_id = student.id
        WHERE assignment.is_team
        GROUP BY 1
        HAVING count(*) > 1
    ) AS ambiguous_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades cannot tell which team submission belongs to these students, they took part in more than one: %', offenders
            USING ERRCODE = '23505';
    END IF;

    SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
        ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    WHERE resolved_grade.points < 0
        OR resolved_grade.points > resolved_grade.points_possible;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires points between 0 and the assignment points_possible, out of range for: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- Read the bound from the constraint rather than repeating the number here,
    -- so the two cannot drift. If the constraint is ever reshaped past this
    -- pattern the limit reads NULL, the comparison matches nothing, and the real
    -- write becomes the only check again; the test suite pins the shape.
    SELECT (regexp_match(
                pg_get_constraintdef(grade_constraint.oid),
                'octet_length\(description\) <= (\d+)'
            ))[1]::integer
    INTO description_limit
    FROM pg_constraint grade_constraint
    JOIN pg_class grade_table
        ON grade_table.oid = grade_constraint.conrelid
    JOIN pg_namespace grade_schema
        ON grade_schema.oid = grade_table.relnamespace
    WHERE grade_schema.nspname = 'data'
        AND grade_table.relname = 'assignment_grade'
        AND grade_constraint.contype = 'c'
        AND pg_get_constraintdef(grade_constraint.oid) LIKE '%octet_length(description)%';

    SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
        ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    WHERE resolved_grade.has_description
        AND octet_length(resolved_grade.description) > description_limit;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires a description of at most % bytes, too long for: %', description_limit, offenders
            USING ERRCODE = '22023';
    END IF;

    -- A team assignment has one submission per team, so two teammates in one
    -- payload are two keys pointing at one row. Rejecting that is the same rule
    -- as the duplicate key above, applied after the netids resolve.
    --
    -- The row does not have to exist yet. Two teammates whose team has never
    -- submitted both resolve to nothing, and would become two inserts against
    -- one unique (team_nickname, assignment_slug) index -- which is the ordinary
    -- shape of a team assignment graded from a per-student file. Keying on the
    -- submission when there is one and on the team it would be created for when
    -- there is not covers both with one rule, so a dry run cannot pass where the
    -- real write would fail.
    SELECT string_agg(target_key || ' (' || netids || ')', ', ' ORDER BY target_key)
        INTO offenders
    FROM (
        SELECT
            resolved_grade.assignment_slug || COALESCE(
                '#' || resolved_grade.assignment_submission_id::text,
                '@' || resolved_grade.team_nickname
            ) AS target_key,
            string_agg(resolved_grade.netid, ' + ' ORDER BY resolved_grade.netid) AS netids
        FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
        WHERE resolved_grade.assignment_submission_id IS NOT NULL
            OR (resolved_grade.is_team AND resolved_grade.team_nickname IS NOT NULL)
        GROUP BY 1
        HAVING count(*) > 1
    ) AS collapsed_submissions;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades received more than one netid for the same submission, send one row per team: %', offenders
            USING ERRCODE = '23505';
    END IF;

    -- Everything below concerns rows with no submission yet, where the current
    -- team_nickname is the only signal there is. That is right for a genuinely
    -- new submission and wrong for anything else, so the cases where it would
    -- be wrong are refused here rather than guessed at.
    SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
        ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    WHERE resolved_grade.is_team
        AND resolved_grade.assignment_submission_id IS NULL
        AND resolved_grade.team_nickname IS NULL;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades cannot create a team submission for a student with no team: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- The student joined their current team after it submitted, so they are not
    -- in its participant snapshot and a second submission for that team cannot
    -- exist. Grading them on work they are not recorded as having done is a
    -- decision for a person.
    SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
        ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    WHERE resolved_grade.is_team
        AND resolved_grade.assignment_submission_id IS NULL
        AND resolved_grade.team_nickname IS NOT NULL
        AND EXISTS (
            SELECT 1
            FROM api.assignment_submissions submission
            WHERE submission.assignment_slug = resolved_grade.assignment_slug
                AND submission.team_nickname = resolved_grade.team_nickname
        );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades will not grade these students on their current team submission, they did not take part in it: %', offenders
            USING ERRCODE = '22023';
    END IF;

    IF NOT p_create_missing_submissions THEN
        SELECT string_agg(resolved_grade.assignment_slug || '/' || resolved_grade.netid, ', '
            ORDER BY resolved_grade.assignment_slug || '/' || resolved_grade.netid) INTO offenders
        FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
        WHERE resolved_grade.assignment_submission_id IS NULL;

        IF offenders IS NOT NULL THEN
            RAISE EXCEPTION 'import_assignment_grades found no assignment submission for: %', offenders
                USING ERRCODE = '23503';
        END IF;
    END IF;

    SELECT
        count(*) FILTER (
            WHERE existing_grade.assignment_submission_id IS NULL
        )::integer,
        count(*) FILTER (
            WHERE existing_grade.assignment_submission_id IS NOT NULL
                AND (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                    resolved_grade.points,
                    CASE
                        WHEN resolved_grade.has_description THEN resolved_grade.description
                        ELSE existing_grade.description
                    END
                )
        )::integer,
        count(*) FILTER (
            WHERE existing_grade.assignment_submission_id IS NOT NULL
                AND NOT ((existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                    resolved_grade.points,
                    CASE
                        WHEN resolved_grade.has_description THEN resolved_grade.description
                        ELSE existing_grade.description
                    END
                ))
        )::integer,
        count(*) FILTER (
            WHERE resolved_grade.assignment_submission_id IS NULL
        )::integer
    INTO inserted_count, updated_count, unchanged_count, submission_created_count
    FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
    LEFT JOIN api.assignment_grades existing_grade
        ON existing_grade.assignment_submission_id = resolved_grade.assignment_submission_id;

    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'import_assignment_grades accounted for % of % grades', inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_dry_run THEN
        RETURN NEXT;
        RETURN;
    END IF;

    PERFORM set_config('yeluke.grade_event_source', 'api.import_assignment_grades', true);
    PERFORM set_config('yeluke.grade_event_reason', COALESCE(p_reason, ''), true);
    PERFORM set_config('yeluke.grade_event_import_id', import_id, true);

    -- data.assignment_grade cannot exist without a submission to hang it on, and
    -- a paper exam never produces one, so an import that refuses to create them
    -- could never record a paper grade at all. The participant snapshot on a
    -- created team submission is the roster as of import time, which is the only
    -- roster the database has.
    --
    -- This runs unconditionally: when p_create_missing_submissions is false the
    -- check above has already failed the import, so there is nothing to create.
    WITH missing_submissions AS (
        SELECT
            resolved_grade.assignment_slug,
            resolved_grade.is_team,
            resolved_grade.user_id,
            -- The only case where the current team is the right team: there is
            -- no earlier submission to belong to, so this student's team now is
            -- the team doing the work now.
            resolved_grade.team_nickname
        FROM data.resolve_assignment_grade_import(p_grades) AS resolved_grade
        WHERE resolved_grade.assignment_submission_id IS NULL
    ),
    created_submissions AS (
        INSERT INTO api.assignment_submissions (
            assignment_slug,
            is_team,
            user_id,
            team_nickname,
            submitter_user_id
        )
        SELECT
            missing_submission.assignment_slug,
            missing_submission.is_team,
            CASE WHEN missing_submission.is_team THEN NULL ELSE missing_submission.user_id END,
            CASE WHEN missing_submission.is_team THEN missing_submission.team_nickname ELSE NULL END,
            -- An individual submission must be submitted by its own owner, so
            -- the faculty importer cannot be the submitter here.
            missing_submission.user_id
        FROM missing_submissions missing_submission
        RETURNING id
    )
    SELECT count(*)::integer INTO submission_created_count
    FROM created_submissions;

    -- Re-resolving after the inserts above is what makes the newly created
    -- submissions visible, including their freshly snapshotted participants.
    WITH resolved_grades AS (
        SELECT *
        FROM data.resolve_assignment_grade_import(p_grades)
    ),
    updated_grades AS (
        UPDATE api.assignment_grades existing_grade
        SET
            points = resolved_grade.points,
            description = CASE
                WHEN resolved_grade.has_description THEN resolved_grade.description
                ELSE existing_grade.description
            END
        FROM resolved_grades resolved_grade
        WHERE existing_grade.assignment_submission_id = resolved_grade.assignment_submission_id
            AND (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                resolved_grade.points,
                CASE
                    WHEN resolved_grade.has_description THEN resolved_grade.description
                    ELSE existing_grade.description
                END
            )
        RETURNING existing_grade.assignment_submission_id
    ),
    inserted_grades AS (
        INSERT INTO api.assignment_grades (
            assignment_submission_id,
            assignment_slug,
            points_possible,
            points,
            description
        )
        SELECT
            resolved_grade.assignment_submission_id,
            resolved_grade.assignment_slug,
            resolved_grade.points_possible,
            resolved_grade.points,
            resolved_grade.description
        FROM resolved_grades resolved_grade
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.assignment_grades existing_grade
            WHERE existing_grade.assignment_submission_id = resolved_grade.assignment_submission_id
        )
        RETURNING assignment_submission_id
    )
    SELECT
        (SELECT count(*)::integer FROM updated_grades),
        (SELECT count(*)::integer FROM inserted_grades)
    INTO updated_count, inserted_count;

    PERFORM set_config('yeluke.grade_event_source', '', true);
    PERFORM set_config('yeluke.grade_event_reason', '', true);
    PERFORM set_config('yeluke.grade_event_import_id', '', true);

    -- Every payload row has to end up somewhere. The loader this replaces let
    -- rows fall out of an inner join and still reported success.
    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'import_assignment_grades wrote % of % grades', inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION import_assignment_grades(jsonb, boolean, boolean, text, text) FROM PUBLIC;

-- Resolve quiz import rows to the quiz, the student, and the two rows the
-- import may touch: the existing grade's submission and the existing
-- engagement.
--
-- Like data.resolve_assignment_grade_import this lives in the data schema
-- because PostgREST exposes only api, and it is SECURITY INVOKER on purpose so
-- that a caller who cannot see a quiz cannot grade it.
--
-- Resolution is exactly one-to-one in both directions: data.quiz.meeting_slug
-- is UNIQUE and data.user.netid is UNIQUE, so a meeting_slug/netid pair names
-- at most one quiz and one student. There is no team-submission ambiguity to
-- resolve here, which is why this is so much shorter than its assignment twin.
CREATE OR REPLACE FUNCTION data.resolve_quiz_result_import(p_results jsonb)
RETURNS TABLE (
    meeting_slug text,
    netid text,
    quiz_id integer,
    user_id integer,
    points_possible smallint,
    points real,
    has_description boolean,
    description text,
    has_submission boolean,
    participation data.participation_enum
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        quiz.meeting_slug,
        student.netid,
        quiz.id,
        student.id,
        quiz.points_possible,
        (element.value->>'points')::real,
        element.value ? 'description',
        element.value->>'description',
        existing_submission.quiz_id IS NOT NULL,
        existing_engagement.participation
    FROM jsonb_array_elements(p_results) AS element(value)
    JOIN api.quizzes quiz
        ON quiz.meeting_slug = btrim(element.value->>'meeting_slug')
    JOIN api.users student
        ON student.netid = lower(btrim(element.value->>'netid'))
    -- data.quiz_grade has a foreign key onto data.quiz_submission, so this is
    -- what says whether the grade has anything to hang on yet.
    LEFT JOIN api.quiz_submissions existing_submission
        ON existing_submission.quiz_id = quiz.id
        AND existing_submission.user_id = student.id
    -- NULL here means no engagement row at all, which is a different case from
    -- a row that says 'absent'.
    LEFT JOIN api.engagements existing_engagement
        ON existing_engagement.meeting_slug = quiz.meeting_slug
        AND existing_engagement.user_id = student.id;
$$;

REVOKE ALL ON FUNCTION data.resolve_quiz_result_import(jsonb) FROM PUBLIC;

-- Import paper quiz results keyed on meeting_slug + netid.
--
-- Named for the import rather than for the grades because it has a second
-- effect: p_mark_attended records that the people in the file were in the room.
-- That defaults to false so the side effect has to be asked for at the call
-- site rather than discovered afterwards.
--
-- As with api.import_assignment_grades the payload carries final, absolute
-- points. An OMR sheet's correct/total is turned into points client-side, where
-- the full cohort is known; a denominator derived from whichever rows happen to
-- be in one file makes the same raw score mean different things run to run.
--
-- Everything is re-runnable. A second run of the same payload writes nothing,
-- reports every row as unchanged, and appends no redundant 'corrected' rows to
-- data.quiz_grade_event.
CREATE OR REPLACE FUNCTION import_quiz_results(
    p_results jsonb,
    p_mark_attended boolean DEFAULT false,
    p_dry_run boolean DEFAULT false,
    p_import_id text DEFAULT NULL,
    p_reason text DEFAULT NULL
)
RETURNS TABLE (
    inserted_count integer,
    updated_count integer,
    unchanged_count integer,
    submission_created_count integer,
    attendance_inserted integer,
    attendance_updated integer,
    attendance_unchanged integer,
    import_id text,
    dry_run boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    input_count integer;
    description_limit integer;
    offenders text;
BEGIN
    p_mark_attended := COALESCE(p_mark_attended, false);
    p_dry_run := COALESCE(p_dry_run, false);
    dry_run := p_dry_run;
    import_id := COALESCE(nullif(btrim(p_import_id), ''), gen_random_uuid()::text);

    IF p_results IS NULL OR jsonb_typeof(p_results) <> 'array' THEN
        RAISE EXCEPTION 'import_quiz_results expects a JSON array'
            USING ERRCODE = '22023';
    END IF;

    IF octet_length(p_results::text) > 4194304 THEN
        RAISE EXCEPTION 'import_quiz_results payload exceeds the 4 MB limit'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*) INTO input_count
    FROM jsonb_array_elements(p_results);

    IF input_count = 0 THEN
        RAISE EXCEPTION 'import_quiz_results refuses to import an empty result list'
            USING ERRCODE = '22023';
    END IF;

    IF input_count > 2000 THEN
        RAISE EXCEPTION 'import_quiz_results accepts at most 2000 results, received %', input_count
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_results) AS element(value)
        WHERE jsonb_typeof(element.value) <> 'object'
    ) THEN
        RAISE EXCEPTION 'import_quiz_results expects a JSON object for every result'
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(position::text, ', ' ORDER BY position) INTO offenders
    FROM (
        SELECT element.position
        FROM jsonb_array_elements(p_results)
            WITH ORDINALITY AS element(value, position)
        WHERE COALESCE(btrim(element.value->>'meeting_slug'), '') = ''
            OR COALESCE(btrim(element.value->>'netid'), '') = ''
    ) AS incomplete_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires meeting_slug and netid on every result, missing at position: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- A blank cell on an answer sheet is a question no one answered, not a
    -- score of zero. The CSV loader this replaces dropped such rows silently.
    SELECT string_agg(result_key, ', ' ORDER BY result_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'meeting_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS result_key
        FROM jsonb_array_elements(p_results) AS element(value)
        WHERE element.value->'points' IS NULL
            OR jsonb_typeof(element.value->'points') = 'null'
    ) AS scoreless_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires a points value on every result, a missing or null score is not a zero: %', offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(result_key, ', ' ORDER BY result_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'meeting_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS result_key
        FROM jsonb_array_elements(p_results) AS element(value)
        WHERE jsonb_typeof(element.value->'points') <> 'number'
    ) AS non_numeric_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires numeric points: %', offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT string_agg(result_key, ', ' ORDER BY result_key) INTO offenders
    FROM (
        SELECT btrim(element.value->>'meeting_slug')
            || '/' || lower(btrim(element.value->>'netid')) AS result_key
        FROM jsonb_array_elements(p_results) AS element(value)
        GROUP BY 1
        HAVING count(*) > 1
    ) AS duplicate_rows;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results received duplicate meeting_slug/netid key: %', offenders
            USING ERRCODE = '23505';
    END IF;

    -- Quizzes are keyed on the meeting they were sat in, so a meeting that
    -- exists but holds no quiz is just as unimportable as a meeting that does
    -- not exist. Both are named the same way.
    SELECT string_agg(DISTINCT input_result.meeting_slug, ', '
        ORDER BY input_result.meeting_slug) INTO offenders
    FROM (
        SELECT btrim(element.value->>'meeting_slug') AS meeting_slug
        FROM jsonb_array_elements(p_results) AS element(value)
    ) AS input_result
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.quizzes quiz
        WHERE quiz.meeting_slug = input_result.meeting_slug
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results does not know a quiz for meeting slug: %', offenders
            USING ERRCODE = '23503';
    END IF;

    -- The loader this replaces joined netids to users, so an unknown netid
    -- vanished and the run still reported success.
    SELECT string_agg(DISTINCT input_result.netid, ', '
        ORDER BY input_result.netid) INTO offenders
    FROM (
        SELECT lower(btrim(element.value->>'netid')) AS netid
        FROM jsonb_array_elements(p_results) AS element(value)
    ) AS input_result
    WHERE NOT EXISTS (
        SELECT 1
        FROM api.users student
        WHERE student.netid = input_result.netid
    );

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results does not know netid: %', offenders
            USING ERRCODE = '23503';
    END IF;

    SELECT string_agg(resolved_result.meeting_slug || '/' || resolved_result.netid, ', '
        ORDER BY resolved_result.meeting_slug || '/' || resolved_result.netid) INTO offenders
    FROM data.resolve_quiz_result_import(p_results) AS resolved_result
    WHERE resolved_result.points < 0
        OR resolved_result.points > resolved_result.points_possible;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires points between 0 and the quiz points_possible, out of range for: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- Read the bound from the constraint rather than repeating the number here,
    -- so the two cannot drift. If the constraint is ever reshaped past this
    -- pattern the limit reads NULL, the comparison matches nothing, and the real
    -- write becomes the only check again; the test suite pins the shape.
    SELECT (regexp_match(
                pg_get_constraintdef(grade_constraint.oid),
                'octet_length\(description\) <= (\d+)'
            ))[1]::integer
    INTO description_limit
    FROM pg_constraint grade_constraint
    JOIN pg_class grade_table
        ON grade_table.oid = grade_constraint.conrelid
    JOIN pg_namespace grade_schema
        ON grade_schema.oid = grade_table.relnamespace
    WHERE grade_schema.nspname = 'data'
        AND grade_table.relname = 'quiz_grade'
        AND grade_constraint.contype = 'c'
        AND pg_get_constraintdef(grade_constraint.oid) LIKE '%octet_length(description)%';

    SELECT string_agg(resolved_result.meeting_slug || '/' || resolved_result.netid, ', '
        ORDER BY resolved_result.meeting_slug || '/' || resolved_result.netid) INTO offenders
    FROM data.resolve_quiz_result_import(p_results) AS resolved_result
    WHERE resolved_result.has_description
        AND octet_length(resolved_result.description) > description_limit;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_quiz_results requires a description of at most % bytes, too long for: %', description_limit, offenders
            USING ERRCODE = '22023';
    END IF;

    SELECT
        count(*) FILTER (
            WHERE existing_grade.quiz_id IS NULL
        )::integer,
        count(*) FILTER (
            WHERE existing_grade.quiz_id IS NOT NULL
                AND (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                    resolved_result.points,
                    CASE
                        WHEN resolved_result.has_description THEN resolved_result.description
                        ELSE existing_grade.description
                    END
                )
        )::integer,
        count(*) FILTER (
            WHERE existing_grade.quiz_id IS NOT NULL
                AND NOT ((existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                    resolved_result.points,
                    CASE
                        WHEN resolved_result.has_description THEN resolved_result.description
                        ELSE existing_grade.description
                    END
                ))
        )::integer,
        count(*) FILTER (
            WHERE NOT resolved_result.has_submission
        )::integer,
        count(*) FILTER (
            WHERE p_mark_attended
                AND resolved_result.participation IS NULL
        )::integer,
        count(*) FILTER (
            WHERE p_mark_attended
                AND resolved_result.participation = 'absent'::data.participation_enum
        )::integer,
        count(*) FILTER (
            WHERE p_mark_attended
                AND resolved_result.participation IS NOT NULL
                AND resolved_result.participation <> 'absent'::data.participation_enum
        )::integer
    INTO inserted_count, updated_count, unchanged_count, submission_created_count,
        attendance_inserted, attendance_updated, attendance_unchanged
    FROM data.resolve_quiz_result_import(p_results) AS resolved_result
    LEFT JOIN api.quiz_grades existing_grade
        ON existing_grade.quiz_id = resolved_result.quiz_id
        AND existing_grade.user_id = resolved_result.user_id;

    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'import_quiz_results accounted for % of % results', inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_mark_attended
        AND attendance_inserted + attendance_updated + attendance_unchanged <> input_count THEN
        RAISE EXCEPTION 'import_quiz_results accounted for % of % attendance rows', attendance_inserted + attendance_updated + attendance_unchanged, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_dry_run THEN
        RETURN NEXT;
        RETURN;
    END IF;

    PERFORM set_config('yeluke.grade_event_source', 'api.import_quiz_results', true);
    PERFORM set_config('yeluke.grade_event_reason', COALESCE(p_reason, ''), true);
    PERFORM set_config('yeluke.grade_event_import_id', import_id, true);

    -- data.quiz_grade has a foreign key onto data.quiz_submission, and quizzes
    -- are paper-only, so nothing a student does ever creates the submission a
    -- grade needs. An import that refused to create them could not record a
    -- paper quiz grade at all, which is why there is no flag to turn this off:
    -- the only setting it could take is the one that never works.
    WITH created_submissions AS (
        INSERT INTO api.quiz_submissions (quiz_id, user_id)
        SELECT resolved_result.quiz_id, resolved_result.user_id
        FROM data.resolve_quiz_result_import(p_results) AS resolved_result
        WHERE NOT resolved_result.has_submission
        RETURNING quiz_id
    )
    SELECT count(*)::integer INTO submission_created_count
    FROM created_submissions;

    WITH resolved_results AS (
        SELECT *
        FROM data.resolve_quiz_result_import(p_results)
    ),
    updated_grades AS (
        UPDATE api.quiz_grades existing_grade
        SET
            points = resolved_result.points,
            description = CASE
                WHEN resolved_result.has_description THEN resolved_result.description
                ELSE existing_grade.description
            END
        FROM resolved_results resolved_result
        WHERE existing_grade.quiz_id = resolved_result.quiz_id
            AND existing_grade.user_id = resolved_result.user_id
            AND (existing_grade.points, existing_grade.description) IS DISTINCT FROM (
                resolved_result.points,
                CASE
                    WHEN resolved_result.has_description THEN resolved_result.description
                    ELSE existing_grade.description
                END
            )
        RETURNING existing_grade.quiz_id
    ),
    inserted_grades AS (
        INSERT INTO api.quiz_grades (
            quiz_id,
            user_id,
            points_possible,
            points,
            description
        )
        SELECT
            resolved_result.quiz_id,
            resolved_result.user_id,
            resolved_result.points_possible,
            resolved_result.points,
            resolved_result.description
        FROM resolved_results resolved_result
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.quiz_grades existing_grade
            WHERE existing_grade.quiz_id = resolved_result.quiz_id
                AND existing_grade.user_id = resolved_result.user_id
        )
        RETURNING quiz_id
    )
    SELECT
        (SELECT count(*)::integer FROM updated_grades),
        (SELECT count(*)::integer FROM inserted_grades)
    INTO updated_count, inserted_count;

    PERFORM set_config('yeluke.grade_event_source', '', true);
    PERFORM set_config('yeluke.grade_event_reason', '', true);
    PERFORM set_config('yeluke.grade_event_import_id', '', true);

    -- Attendance last, so the participation values read above are the ones this
    -- import found rather than the ones it just wrote.
    --
    -- data.ensure_student_engagement_rows() has already written an 'absent' row
    -- for every (student, meeting) pair that existed when the student was
    -- enrolled, which is why the loaders this replaces marked nobody attended:
    -- their INSERT ... ON CONFLICT DO NOTHING always hit that row and did
    -- nothing. Promoting 'absent' is the whole point.
    --
    -- 'contributed' and 'led' are faculty judgements that outrank mere
    -- presence, and 'attended' is already the value being written, so the
    -- update touches 'absent' and nothing else. Any participation value added
    -- to data.participation_enum later is left alone until someone decides
    -- where it sits; the test suite pins the enum's labels so that decision
    -- cannot be skipped by accident.
    IF p_mark_attended THEN
        WITH resolved_results AS (
            SELECT *
            FROM data.resolve_quiz_result_import(p_results)
        ),
        promoted_engagements AS (
            UPDATE api.engagements existing_engagement
            SET participation = 'attended'::data.participation_enum
            FROM resolved_results resolved_result
            WHERE existing_engagement.user_id = resolved_result.user_id
                AND existing_engagement.meeting_slug = resolved_result.meeting_slug
                AND existing_engagement.participation = 'absent'::data.participation_enum
            RETURNING existing_engagement.user_id
        ),
        -- A meeting created after a student enrolled has no engagement row for
        -- them: nothing backfills one. Those are inserts, not promotions.
        added_engagements AS (
            INSERT INTO api.engagements (user_id, meeting_slug, participation)
            SELECT
                resolved_result.user_id,
                resolved_result.meeting_slug,
                'attended'::data.participation_enum
            FROM resolved_results resolved_result
            WHERE resolved_result.participation IS NULL
            RETURNING user_id
        )
        SELECT
            (SELECT count(*)::integer FROM added_engagements),
            (SELECT count(*)::integer FROM promoted_engagements)
        INTO attendance_inserted, attendance_updated;
    END IF;

    -- Every payload row has to end up somewhere. The loader this replaces let
    -- rows fall out of an inner join and still reported success.
    IF inserted_count + updated_count + unchanged_count <> input_count THEN
        RAISE EXCEPTION 'import_quiz_results wrote % of % results', inserted_count + updated_count + unchanged_count, input_count
            USING ERRCODE = 'XX000';
    END IF;

    IF p_mark_attended
        AND attendance_inserted + attendance_updated + attendance_unchanged <> input_count THEN
        RAISE EXCEPTION 'import_quiz_results wrote % of % attendance rows', attendance_inserted + attendance_updated + attendance_unchanged, input_count
            USING ERRCODE = 'XX000';
    END IF;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION import_quiz_results(jsonb, boolean, boolean, text, text) FROM PUBLIC;

-- Read the fractional_credit bounds off a grade exception table's own CHECK
-- constraint, so the extension functions cannot drift from the schema they
-- write to.
--
-- If the constraint is ever reshaped past this pattern both bounds read NULL,
-- every comparison against them is NULL rather than true, and the real write
-- becomes the only check again; the test suite pins the shape so that a reshape
-- is noticed rather than silently tolerated.
CREATE OR REPLACE FUNCTION data.grade_exception_credit_bounds(p_table_name text)
RETURNS TABLE (
    credit_minimum numeric,
    credit_maximum numeric
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        (regexp_match(
            pg_get_constraintdef(credit_constraint.oid),
            'fractional_credit >= \(([0-9.]+)\)::numeric'
        ))[1]::numeric,
        (regexp_match(
            pg_get_constraintdef(credit_constraint.oid),
            'fractional_credit <= \(([0-9.]+)\)::numeric'
        ))[1]::numeric
    FROM pg_constraint credit_constraint
    JOIN pg_class exception_table
        ON exception_table.oid = credit_constraint.conrelid
    JOIN pg_namespace exception_schema
        ON exception_schema.oid = exception_table.relnamespace
    WHERE exception_schema.nspname = 'data'
        AND exception_table.relname = p_table_name
        AND credit_constraint.contype = 'c'
        AND pg_get_constraintdef(credit_constraint.oid) LIKE '%fractional_credit%';
$$;

REVOKE ALL ON FUNCTION data.grade_exception_credit_bounds(text) FROM PUBLIC;

-- Write one assignment grade exception, creating it or moving the one already
-- there.
--
-- This exists as its own function only so that the ON CONFLICT clauses can name
-- assignment_slug, user_id, team_nickname and is_team as bare columns. Inside
-- api.grant_assignment_extension those are OUT parameter names, and plpgsql
-- substitutes a variable for any unqualified identifier that matches one --
-- which an index inference clause cannot be written around, because it accepts
-- no table qualification.
--
-- It is SECURITY INVOKER and writes through the api view, so the caller's own
-- RLS applies: the WITH CHECK on data.assignment_grade_exception still requires
-- the writer to be faculty.
CREATE OR REPLACE FUNCTION data.upsert_assignment_grade_exception(
    p_assignment_slug text,
    p_is_team boolean,
    p_user_id integer,
    p_team_nickname text,
    p_closed_at timestamptz,
    p_fractional_credit numeric
)
RETURNS TABLE (
    written_id integer,
    was_inserted boolean
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- The uniqueness rules are partial indexes, so each branch has to state the
    -- predicate its arbiter carries. This is exactly what PostgREST's
    -- on_conflict cannot say, and why extending a deadline is an RPC rather
    -- than a POST to a view faculty already hold CRUD on.
    --
    -- fractional_credit is in both DO UPDATE lists. The scripts this replaces
    -- left it out, so re-granting an extension at reduced credit silently kept
    -- whatever credit the first grant had.
    --
    -- was_inserted comes out of the write itself rather than a read taken
    -- before it. Two faculty granting the same new extension at once would both
    -- pass a prior existence check and both be told they created the row, even
    -- though one of them conflict-updated the other's.
    --
    -- old is NULL on the insert path and the pre-update row on the conflict
    -- path. The older idiom for this is RETURNING (xmax = 0), which does not
    -- work here: xmax is a system column, an auto-updatable view has no system
    -- columns in its rowtype, and these writes go through api views on purpose
    -- so that RLS applies. old.id is an ordinary column reference and resolves
    -- through the view. It needs PostgreSQL 18, which is what this schema
    -- already requires.
    IF p_is_team THEN
        INSERT INTO api.assignment_grade_exceptions (
            assignment_slug, is_team, team_nickname, closed_at, fractional_credit
        )
        VALUES (
            p_assignment_slug, true, p_team_nickname, p_closed_at, p_fractional_credit
        )
        ON CONFLICT (assignment_slug, team_nickname) WHERE is_team
        DO UPDATE SET
            closed_at = EXCLUDED.closed_at,
            fractional_credit = EXCLUDED.fractional_credit
        RETURNING new.id, old.id IS NULL INTO written_id, was_inserted;
    ELSE
        INSERT INTO api.assignment_grade_exceptions (
            assignment_slug, is_team, user_id, closed_at, fractional_credit
        )
        VALUES (
            p_assignment_slug, false, p_user_id, p_closed_at, p_fractional_credit
        )
        ON CONFLICT (assignment_slug, user_id) WHERE NOT is_team
        DO UPDATE SET
            closed_at = EXCLUDED.closed_at,
            fractional_credit = EXCLUDED.fractional_credit
        RETURNING new.id, old.id IS NULL INTO written_id, was_inserted;
    END IF;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION data.upsert_assignment_grade_exception(text, boolean, integer, text, timestamptz, numeric) FROM PUBLIC;

-- Grant one student, or one student's team, a later deadline on an assignment.
--
-- p_closed_at is absolute. The script this replaces accepted '+7 days' and
-- interpolated it into SQL, which put a client-side convenience inside the
-- database; relative arithmetic belongs to whoever knows what "a week" means
-- for this course.
--
-- On a team assignment the student's CURRENT team is the right team, which is
-- the opposite of the rule api.import_assignment_grades follows. A grade is a
-- record of work already done, so it is attached through the insert-time
-- participant snapshot in data.assignment_submission_participant. An extension
-- authorises work not yet done, and
-- data.assignment_field_submission_is_writable_by_current_user() reads it by
-- joining the exception's team_nickname to the submitting student's current
-- team_nickname. An older team snapshotted here would write a row that the
-- check consuming it could never match.
CREATE OR REPLACE FUNCTION grant_assignment_extension(
    p_user_id integer,
    p_assignment_slug text,
    p_closed_at timestamptz,
    p_fractional_credit numeric DEFAULT 1
)
RETURNS TABLE (
    exception_id integer,
    assignment_slug text,
    is_team boolean,
    user_id integer,
    team_nickname text,
    closed_at timestamptz,
    fractional_credit numeric,
    created boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Everything the queries below read is held in a local whose name matches
    -- no column of any table touched here. The OUT parameters are named for the
    -- JSON the client wants back, and plpgsql refuses an unqualified identifier
    -- that could be either a variable or a column.
    target_slug text;
    target_is_team boolean;
    target_team_nickname text;
    credit_floor numeric;
    credit_ceiling numeric;
BEGIN
    p_fractional_credit := COALESCE(p_fractional_credit, 1);
    target_slug := btrim(p_assignment_slug);

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'grant_assignment_extension requires a user id'
            USING ERRCODE = '22023';
    END IF;

    IF COALESCE(target_slug, '') = '' THEN
        RAISE EXCEPTION 'grant_assignment_extension requires an assignment slug'
            USING ERRCODE = '22023';
    END IF;

    -- A NULL deadline would be refused by the NOT NULL column anyway; saying so
    -- here names the argument that was left out.
    IF p_closed_at IS NULL THEN
        RAISE EXCEPTION 'grant_assignment_extension requires a closed_at, an extension with no deadline is not an extension'
            USING ERRCODE = '22023';
    END IF;

    SELECT bounds.credit_minimum, bounds.credit_maximum
    INTO credit_floor, credit_ceiling
    FROM data.grade_exception_credit_bounds('assignment_grade_exception') AS bounds;

    IF p_fractional_credit < credit_floor OR p_fractional_credit > credit_ceiling THEN
        RAISE EXCEPTION 'grant_assignment_extension requires fractional_credit between % and %, received %',
            credit_floor, credit_ceiling, p_fractional_credit
            USING ERRCODE = '22023';
    END IF;

    -- Read through api.assignments rather than data.assignment so the caller's
    -- own row visibility applies: a caller who cannot see an assignment cannot
    -- extend it.
    SELECT assignment.is_team INTO target_is_team
    FROM api.assignments assignment
    WHERE assignment.slug = target_slug;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'grant_assignment_extension does not know assignment slug: %', target_slug
            USING ERRCODE = '23503';
    END IF;

    SELECT student.team_nickname INTO target_team_nickname
    FROM api.users student
    WHERE student.id = p_user_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'grant_assignment_extension does not know user id: %', p_user_id
            USING ERRCODE = '23503';
    END IF;

    IF target_is_team AND target_team_nickname IS NULL THEN
        RAISE EXCEPTION 'grant_assignment_extension cannot extend team assignment % for user %, who is on no team', target_slug, p_user_id
            USING ERRCODE = '22023';
    END IF;

    -- A team exception names the team and no user, an individual exception the
    -- other way round; the matches_assignment_is_team constraint refuses
    -- anything else.
    IF NOT target_is_team THEN
        target_team_nickname := NULL;
    END IF;

    -- created comes back out of the write, not out of a read taken before it,
    -- so two faculty granting the same new extension at once cannot both be
    -- told they created the row.
    SELECT written.written_id, written.was_inserted
    INTO exception_id, created
    FROM data.upsert_assignment_grade_exception(
        target_slug, target_is_team, p_user_id, target_team_nickname,
        p_closed_at, p_fractional_credit
    ) AS written;

    assignment_slug := target_slug;
    is_team := target_is_team;
    user_id := CASE WHEN target_is_team THEN NULL ELSE p_user_id END;
    team_nickname := target_team_nickname;
    closed_at := p_closed_at;
    fractional_credit := p_fractional_credit;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION grant_assignment_extension(integer, text, timestamptz, numeric) FROM PUBLIC;

-- Write one quiz grade exception, creating it or moving the one already there.
--
-- Split out for the same reason as its assignment twin: quiz_id and user_id are
-- OUT parameter names in api.grant_quiz_extension, and an ON CONFLICT target
-- takes no table qualification to disambiguate them from.
CREATE OR REPLACE FUNCTION data.upsert_quiz_grade_exception(
    p_quiz_id integer,
    p_user_id integer,
    p_closed_at timestamptz,
    p_fractional_credit numeric
)
RETURNS TABLE (
    written_id integer,
    was_inserted boolean
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Unlike the assignment exceptions this arbiter is a plain UNIQUE
    -- constraint, so PostgREST could express the conflict target. What it
    -- cannot do is resolve a meeting slug to a quiz id and upsert on the result
    -- in one transaction, which is what api.grant_quiz_extension is for.
    --
    -- old.id IS NULL says which branch this took, for the reasons set out on
    -- data.upsert_assignment_grade_exception.
    INSERT INTO api.quiz_grade_exceptions (
        quiz_id, user_id, closed_at, fractional_credit
    )
    VALUES (
        p_quiz_id, p_user_id, p_closed_at, p_fractional_credit
    )
    ON CONFLICT (quiz_id, user_id)
    DO UPDATE SET
        closed_at = EXCLUDED.closed_at,
        fractional_credit = EXCLUDED.fractional_credit
    RETURNING new.id, old.id IS NULL INTO written_id, was_inserted;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION data.upsert_quiz_grade_exception(integer, integer, timestamptz, numeric) FROM PUBLIC;

-- Grant one student a later deadline on a quiz, keyed on the meeting the quiz
-- was sat in.
--
-- Non-destructive by construction. The script this replaces was named
-- add-quiz-grade-exception but opened by deleting the student's quiz_grade,
-- quiz_answer and quiz_submission rows -- and data.quiz_answer has not existed
-- since quizzes went paper-only, so the script raises before it writes
-- anything. Nothing here removes a grade. A retake is a re-import through
-- api.import_quiz_results, which updates the grade in place and leaves both the
-- original 'recorded' event and the later 'corrected' event in
-- api.quiz_grade_events.
--
-- Quizzes are paper-only, so no student-facing write path currently reads this
-- row: data.quiz_submission's RLS admits faculty only, and nothing in the
-- schema consults data.quiz_grade_exception. The row is the durable record of a
-- faculty decision, and the place any future make-up window would be read from.
CREATE OR REPLACE FUNCTION grant_quiz_extension(
    p_user_id integer,
    p_meeting_slug text,
    p_closed_at timestamptz,
    p_fractional_credit numeric DEFAULT 1
)
RETURNS TABLE (
    exception_id integer,
    meeting_slug text,
    quiz_id integer,
    user_id integer,
    closed_at timestamptz,
    fractional_credit numeric,
    created boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Locals named away from every column these queries read, for the same
    -- reason as in api.grant_assignment_extension.
    target_slug text;
    target_quiz_id integer;
    credit_floor numeric;
    credit_ceiling numeric;
BEGIN
    p_fractional_credit := COALESCE(p_fractional_credit, 1);
    target_slug := btrim(p_meeting_slug);

    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'grant_quiz_extension requires a user id'
            USING ERRCODE = '22023';
    END IF;

    IF COALESCE(target_slug, '') = '' THEN
        RAISE EXCEPTION 'grant_quiz_extension requires a meeting slug'
            USING ERRCODE = '22023';
    END IF;

    IF p_closed_at IS NULL THEN
        RAISE EXCEPTION 'grant_quiz_extension requires a closed_at, an extension with no deadline is not an extension'
            USING ERRCODE = '22023';
    END IF;

    SELECT bounds.credit_minimum, bounds.credit_maximum
    INTO credit_floor, credit_ceiling
    FROM data.grade_exception_credit_bounds('quiz_grade_exception') AS bounds;

    IF p_fractional_credit < credit_floor OR p_fractional_credit > credit_ceiling THEN
        RAISE EXCEPTION 'grant_quiz_extension requires fractional_credit between % and %, received %',
            credit_floor, credit_ceiling, p_fractional_credit
            USING ERRCODE = '22023';
    END IF;

    -- Quizzes are keyed on the meeting they were sat in, so a meeting that
    -- exists but holds no quiz is just as unextendable as a meeting that does
    -- not exist. Both are named the same way. Reading through api.quizzes keeps
    -- the caller's own row visibility in force.
    SELECT quiz.id INTO target_quiz_id
    FROM api.quizzes quiz
    WHERE quiz.meeting_slug = target_slug;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'grant_quiz_extension does not know a quiz for meeting slug: %', target_slug
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM api.users student
        WHERE student.id = p_user_id
    ) THEN
        RAISE EXCEPTION 'grant_quiz_extension does not know user id: %', p_user_id
            USING ERRCODE = '23503';
    END IF;

    -- created comes back out of the write, not out of a read taken before it,
    -- so two faculty granting the same new extension at once cannot both be
    -- told they created the row.
    SELECT written.written_id, written.was_inserted
    INTO exception_id, created
    FROM data.upsert_quiz_grade_exception(
        target_quiz_id, p_user_id, p_closed_at, p_fractional_credit
    ) AS written;

    meeting_slug := target_slug;
    quiz_id := target_quiz_id;
    user_id := p_user_id;
    closed_at := p_closed_at;
    fractional_credit := p_fractional_credit;

    RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION grant_quiz_extension(integer, text, timestamptz, numeric) FROM PUBLIC;
