
CREATE TABLE IF NOT EXISTS assignment_field (
    slug TEXT
        CHECK (slug ~ '^[a-z0-9-]+$' AND char_length(slug) < 30),
    assignment_slug VARCHAR(100)
        REFERENCES assignment(slug)
        ON DELETE CASCADE ON UPDATE CASCADE
        NOT NULL,
    label VARCHAR(100) NOT NULL,
    help VARCHAR(200) NOT NULL,
    placeholder VARCHAR(100) NOT NULL,
    is_url BOOLEAN NOT NULL DEFAULT false,
    is_multiline BOOLEAN NOT NULL DEFAULT false,
    display_order SMALLINT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT url_not_multiline CHECK (NOT (is_url AND is_multiline)),
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    PRIMARY KEY (slug, assignment_slug) -- For foreign keys\
);

-- TODO: add ability include regular expressions and 
-- similar things to validate user input. Right now,
-- `is_url` and `is_multiline` are only used for the UI,
-- they are not used for validation.


DROP TRIGGER IF EXISTS tg_assignment_default ON assignment;
CREATE TRIGGER tg_assignment_default
    BEFORE INSERT OR UPDATE
    ON assignment
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();