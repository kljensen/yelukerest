CREATE TABLE IF NOT EXISTS assignment_field_submission (
    -- Need to ensure that this 
    assignment_submission_id INT NOT NULL,
    assignment_field_id INT NOT NULL,
    -- This table will point to an assignment field
    -- and a assignment submission. How do we know
    -- that the submission and field correspond to 
    -- the same assignment? We need to drag along
    -- the assignment slug.
    assignment_slug VARCHAR(100) NOT NULL,
    -- You can only submit one answer per field per submission,
    -- so it is a good primary key.
    PRIMARY KEY (assignment_submission_id, assignment_field_id),
    FOREIGN KEY
        (assignment_submission_id, assignment_slug)
        REFERENCES assignment_submission(id, assignment_slug)
        ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY
        (assignment_field_id, assignment_slug)
        REFERENCES assignment_field(id, assignment_slug)
        ON DELETE CASCADE ON UPDATE CASCADE,
    body VARCHAR(10000) NOT NULL,
    submitter_user_id INT REFERENCES "user"(id)
        ON DELETE CASCADE
        ON UPDATE CASCADE NOT NULL DEFAULT request.user_id(),
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp
);


CREATE OR REPLACE FUNCTION fill_assignment_field_submission_defaults()
RETURNS TRIGGER AS $$
BEGIN
    -- Fill in the assignment_slug if it is null
    IF (NEW.assignment_slug IS NULL) THEN
        SELECT assignment_slug INTO NEW.assignment_slug
        FROM api.assignment_fields
        WHERE id = NEW.assignment_field_id;
    END IF;
    -- Fill in the assignment_submission_id if it is null.
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
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE OR REPLACE FUNCTION fill_assignment_field_submission_update_defaults()
RETURNS TRIGGER AS $$
BEGIN
    -- TODO: Should I only do this for people in
    -- the 'student' role, or != 'faculty' role?
    IF (request.user_id() IS NOT NULL) THEN
        NEW.submitter_user_id = request.user_id();
    END IF;
    RETURN NEW;
END;
$$ language 'plpgsql';

DROP TRIGGER IF EXISTS tg_assignment_field_submission_default ON assignment_field_submission;
CREATE TRIGGER tg_assignment_field_submission_default
    BEFORE INSERT OR UPDATE
            ON assignment_field_submission
    FOR EACH ROW
EXECUTE PROCEDURE fill_assignment_field_submission_defaults();

DROP TRIGGER IF EXISTS tg_assignment_field_submission_update_default ON assignment_field_submission;
CREATE TRIGGER tg_assignment_field_submission_update_default
    BEFORE INSERT OR UPDATE
            ON assignment_field_submission
    FOR EACH ROW
EXECUTE PROCEDURE fill_assignment_field_submission_update_defaults();