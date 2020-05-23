
CREATE TABLE IF NOT EXISTS assignment_field (
    slug TEXT
        CHECK (slug ~ '^[a-z0-9-]+$' AND char_length(slug) < 30),
    assignment_slug VARCHAR(100)
        REFERENCES assignment(slug)
        ON UPDATE CASCADE
        NOT NULL,
    label VARCHAR(100) NOT NULL,
    help VARCHAR(200) NOT NULL,
    placeholder VARCHAR(100) NOT NULL,
    is_url BOOLEAN NOT NULL DEFAULT false,
    is_multiline BOOLEAN NOT NULL DEFAULT false,
    display_order SMALLINT NOT NULL DEFAULT 0,
    -- The regular expression
    pattern TEXT,
    example TEXT,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT url_not_multiline CHECK (NOT (is_url AND is_multiline)),
    CONSTRAINT url_matches_example CHECK (
        example is NULL
        OR
        is_url is FALSE
        OR
        example ~* 'https?://'
    ),
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at),
    -- If there is a `pattern`, we also expect to receive an `example`
    -- and the `example` should match the `pattern`. This has the side
    -- effect of ensuring the `pattern` is a valid regular expression.
    -- The regex should be valid both for Postgres (POSIX 1003.2) and
    -- for JavaScript/HTML5. We change the pattern below to match the
    -- default HTML5 behavior as described here:
    -- https://html.spec.whatwg.org/multipage/input.html#the-pattern-attribute
    -- This has the effect of anchoring the pattern to the beginning
    -- and end of the string: making the full `example` match.
    CONSTRAINT pattern_requires_example CHECK (
        (pattern IS NULL)
        OR
        (pattern IS NOT NULL AND example is NOT NULL)
    ),
    CONSTRAINT pattern_is_regex CHECK (
        (pattern IS NULL)
        OR
        (example ~ ('^(?:' || pattern || ')$')) IS TRUE
    ),
    PRIMARY KEY (slug, assignment_slug), 
    -- We need this unique index in order to pass
    -- along the `is_url` and `pattern` attributes
    -- to `data.assignment_field_submission` rows.
    UNIQUE(slug, assignment_slug, is_url, pattern)
);


DROP TRIGGER IF EXISTS tg_assignment_default ON assignment;
CREATE TRIGGER tg_assignment_default
    BEFORE INSERT OR UPDATE
    ON assignment
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();