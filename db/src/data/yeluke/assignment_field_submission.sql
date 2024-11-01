CREATE TABLE IF NOT EXISTS assignment_field_submission (
    -- Need to ensure that this 
    assignment_submission_id INT NOT NULL,
    assignment_field_slug TEXT NOT NULL,
    -- This table will point to an assignment field
    -- and a assignment submission. How do we know
    -- that the submission and field correspond to 
    -- the same assignment? We need to drag along
    -- the assignment slug. This is a "diamond"
    -- dependency pattern.
    assignment_slug TEXT NOT NULL,
    assignment_field_is_url BOOLEAN NOT NULL,
    assignment_field_pattern TEXT NOT NULL,
    -- You can only submit one answer per field per submission,
    -- so it is a good primary key.
    PRIMARY KEY (assignment_submission_id, assignment_field_slug),
    FOREIGN KEY
        (assignment_submission_id, assignment_slug)
        REFERENCES assignment_submission(id, assignment_slug)
        ON UPDATE CASCADE,
    FOREIGN KEY
        (assignment_field_slug, assignment_slug, assignment_field_is_url, assignment_field_pattern)
        REFERENCES assignment_field(slug, assignment_slug, is_url, pattern)
        ON UPDATE CASCADE,
    body TEXT NOT NULL,
    submitter_user_id INT
        REFERENCES "user"(id)
        ON UPDATE CASCADE
        NOT NULL DEFAULT request.user_id(),
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp
    CONSTRAINT body_matches_pattern CHECK ( text_matches(body, assignment_field_pattern)),
    CONSTRAINT body_matches_is_url CHECK (
        (assignment_field_is_url IS FALSE)
        OR
        text_is_url(body)
    )
);


CREATE OR REPLACE FUNCTION fill_assignment_field_submission_defaults()
RETURNS TRIGGER AS $$
BEGIN
    -- Fill in the assignment_slug if it is NULL by looking
    -- at the assignment_slug from the assignment_submission.
    IF (NEW.assignment_slug IS NULL AND NEW.assignment_submission_id IS NOT NULL) THEN
        SELECT assignment_slug INTO NEW.assignment_slug
        FROM api.assignment_submissions
        WHERE id = NEW.assignment_submission_id;
    END IF;
    -- Fill in the assignment_submission_id if it is null
    -- by looking at the assignment if the assignment_slug
    -- is not null.
    IF (NEW.assignment_submission_id IS NULL and NEW.assignment_slug IS NOT NULL and request.user_id() IS NOT NULL) THEN
        SELECT ass.id INTO NEW.assignment_submission_id
        FROM
            (api.assignment_submissions ass
            LEFT OUTER JOIN api.users u
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
            FROM api.assignment_submissions AS sub
            WHERE sub.id = NEW.assignment_submission_id;
        END IF;
    ELSE
        NEW.submitter_user_id = request.user_id();
    END IF;

    -- Try to fill in `pattern`
    IF (NEW.assignment_field_pattern is NULL) THEN
        SELECT pattern INTO NEW.assignment_field_pattern
        FROM api.assignment_fields AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    -- Try to fill in `is_url`
    IF (NEW.assignment_field_is_url is NULL) THEN
        SELECT is_url INTO NEW.assignment_field_is_url
        FROM api.assignment_fields AS af
        WHERE NEW.assignment_field_slug=af.slug AND NEW.assignment_slug = af.assignment_slug;
    END IF;

    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';


DROP TRIGGER IF EXISTS tg_assignment_field_submission_default ON assignment_field_submission;
CREATE TRIGGER tg_assignment_field_submission_default
    BEFORE INSERT OR UPDATE
            ON assignment_field_submission
    FOR EACH ROW
EXECUTE PROCEDURE fill_assignment_field_submission_defaults();
