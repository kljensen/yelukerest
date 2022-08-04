-- Tests if the first argument matches the regex in
-- the second argument.
create or replace function text_matches(text, text) returns bool as $$
    select $1 ~ ('^(?:' || $2 || ')$')
$$ stable language sql;

-- Check if a value looks like a URL. Here, I'm going to get false negatives,
-- but for the most part I don't care. See
-- https://mathiasbynens.be/demo/url-regex
create or replace function text_is_url(text) returns bool as $$
    SELECT $1 ~* '^https?://[a-z0-9]+'
$$ stable language sql;

CREATE TABLE IF NOT EXISTS assignment_field (
    slug TEXT
        CHECK (slug ~ '^[a-z0-9-]+$' AND char_length(slug) < 30),
    assignment_slug TEXT
        CHECK (char_length(assignment_slug) < 100)
        REFERENCES assignment(slug)
        ON UPDATE CASCADE
        NOT NULL,
    label TEXT NOT NULL
        CHECK (char_length(label) < 100),
    help TEXT NOT NULL
        CHECK (char_length(help) < 200),
    placeholder TEXT NOT NULL
        CHECK (char_length(placeholder) < 100),
    is_url BOOLEAN NOT NULL DEFAULT false,
    is_multiline BOOLEAN NOT NULL DEFAULT false,
    display_order SMALLINT NOT NULL DEFAULT 0,
    -- The regular expression
    pattern TEXT NOT NULL DEFAULT '.*',
    example TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT url_not_multiline CHECK (NOT (is_url AND is_multiline)),
    CONSTRAINT url_matches_example CHECK (
        (is_url is FALSE)
        OR
        (is_url is TRUE and text_is_url(example))
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
    CONSTRAINT pattern_matches_example CHECK (text_matches(example, pattern)),
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
