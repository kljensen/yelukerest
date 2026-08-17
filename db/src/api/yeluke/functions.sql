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

    SELECT string_agg(assignment.slug || '/' || student.netid, ', '
        ORDER BY assignment.slug || '/' || student.netid) INTO offenders
    FROM (
        SELECT
            btrim(element.value->>'assignment_slug') AS assignment_slug,
            lower(btrim(element.value->>'netid')) AS netid
        FROM jsonb_array_elements(p_grades) AS element(value)
    ) AS input_grade
    JOIN api.assignments assignment
        ON assignment.slug = input_grade.assignment_slug
    JOIN api.users student
        ON student.netid = input_grade.netid
    WHERE assignment.is_team
        AND student.team_nickname IS NULL;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades cannot reach a team submission for a student with no team: %', offenders
            USING ERRCODE = '22023';
    END IF;

    -- A team assignment has one submission per team, so two teammates in one
    -- payload are two keys pointing at one row. Rejecting that is the same rule
    -- as the duplicate key above, applied after the netid resolves to a team.
    SELECT string_agg(team_key || ' (' || netids || ')', ', ' ORDER BY team_key)
        INTO offenders
    FROM (
        SELECT
            assignment.slug || '/' || student.team_nickname AS team_key,
            string_agg(student.netid, ' + ' ORDER BY student.netid) AS netids
        FROM (
            SELECT
                btrim(element.value->>'assignment_slug') AS assignment_slug,
                lower(btrim(element.value->>'netid')) AS netid
            FROM jsonb_array_elements(p_grades) AS element(value)
        ) AS input_grade
        JOIN api.assignments assignment
            ON assignment.slug = input_grade.assignment_slug
        JOIN api.users student
            ON student.netid = input_grade.netid
        WHERE assignment.is_team
        GROUP BY 1
        HAVING count(*) > 1
    ) AS collapsed_teams;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades received more than one netid for the same team submission, send one row per team: %', offenders
            USING ERRCODE = '23505';
    END IF;

    SELECT string_agg(assignment.slug || '/' || student.netid, ', '
        ORDER BY assignment.slug || '/' || student.netid) INTO offenders
    FROM (
        SELECT
            btrim(element.value->>'assignment_slug') AS assignment_slug,
            lower(btrim(element.value->>'netid')) AS netid,
            (element.value->>'points')::real AS points
        FROM jsonb_array_elements(p_grades) AS element(value)
    ) AS input_grade
    JOIN api.assignments assignment
        ON assignment.slug = input_grade.assignment_slug
    JOIN api.users student
        ON student.netid = input_grade.netid
    WHERE input_grade.points < 0
        OR input_grade.points > assignment.points_possible;

    IF offenders IS NOT NULL THEN
        RAISE EXCEPTION 'import_assignment_grades requires points between 0 and the assignment points_possible, out of range for: %', offenders
            USING ERRCODE = '22023';
    END IF;

    IF NOT p_create_missing_submissions THEN
        SELECT string_agg(assignment.slug || '/' || student.netid, ', '
            ORDER BY assignment.slug || '/' || student.netid) INTO offenders
        FROM (
            SELECT
                btrim(element.value->>'assignment_slug') AS assignment_slug,
                lower(btrim(element.value->>'netid')) AS netid
            FROM jsonb_array_elements(p_grades) AS element(value)
        ) AS input_grade
        JOIN api.assignments assignment
            ON assignment.slug = input_grade.assignment_slug
        JOIN api.users student
            ON student.netid = input_grade.netid
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.assignment_submissions submission
            WHERE submission.assignment_slug = assignment.slug
                AND CASE
                    WHEN assignment.is_team THEN submission.team_nickname = student.team_nickname
                    ELSE submission.user_id = student.id
                END
        );

        IF offenders IS NOT NULL THEN
            RAISE EXCEPTION 'import_assignment_grades found no assignment submission for: %', offenders
                USING ERRCODE = '23503';
        END IF;
    END IF;

    WITH input_grades AS (
        SELECT
            btrim(element.value->>'assignment_slug') AS assignment_slug,
            lower(btrim(element.value->>'netid')) AS netid,
            (element.value->>'points')::real AS points,
            element.value ? 'description' AS has_description,
            element.value->>'description' AS description
        FROM jsonb_array_elements(p_grades) AS element(value)
    ),
    resolved_grades AS (
        SELECT
            input_grade.points,
            input_grade.has_description,
            input_grade.description,
            submission.id AS assignment_submission_id
        FROM input_grades input_grade
        JOIN api.assignments assignment
            ON assignment.slug = input_grade.assignment_slug
        JOIN api.users student
            ON student.netid = input_grade.netid
        LEFT JOIN api.assignment_submissions submission
            ON submission.assignment_slug = assignment.slug
            AND CASE
                WHEN assignment.is_team THEN submission.team_nickname = student.team_nickname
                ELSE submission.user_id = student.id
            END
    )
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
    FROM resolved_grades resolved_grade
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
    WITH input_grades AS (
        SELECT
            btrim(element.value->>'assignment_slug') AS assignment_slug,
            lower(btrim(element.value->>'netid')) AS netid
        FROM jsonb_array_elements(p_grades) AS element(value)
    ),
    missing_submissions AS (
        SELECT
            assignment.slug AS assignment_slug,
            assignment.is_team,
            student.id AS user_id,
            student.team_nickname
        FROM input_grades input_grade
        JOIN api.assignments assignment
            ON assignment.slug = input_grade.assignment_slug
        JOIN api.users student
            ON student.netid = input_grade.netid
        WHERE NOT EXISTS (
            SELECT 1
            FROM api.assignment_submissions submission
            WHERE submission.assignment_slug = assignment.slug
                AND CASE
                    WHEN assignment.is_team THEN submission.team_nickname = student.team_nickname
                    ELSE submission.user_id = student.id
                END
        )
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

    WITH input_grades AS (
        SELECT
            btrim(element.value->>'assignment_slug') AS assignment_slug,
            lower(btrim(element.value->>'netid')) AS netid,
            (element.value->>'points')::real AS points,
            element.value ? 'description' AS has_description,
            element.value->>'description' AS description
        FROM jsonb_array_elements(p_grades) AS element(value)
    ),
    resolved_grades AS (
        SELECT
            assignment.slug AS assignment_slug,
            assignment.points_possible,
            input_grade.points,
            input_grade.has_description,
            input_grade.description,
            submission.id AS assignment_submission_id
        FROM input_grades input_grade
        JOIN api.assignments assignment
            ON assignment.slug = input_grade.assignment_slug
        JOIN api.users student
            ON student.netid = input_grade.netid
        JOIN api.assignment_submissions submission
            ON submission.assignment_slug = assignment.slug
            AND CASE
                WHEN assignment.is_team THEN submission.team_nickname = student.team_nickname
                ELSE submission.user_id = student.id
            END
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
