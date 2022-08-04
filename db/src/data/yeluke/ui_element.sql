
CREATE TABLE IF NOT EXISTS ui_element (
    key TEXT PRIMARY KEY
        CHECK (key ~ '^[a-z0-9\-]+$' AND char_length(key) < 50),
    body TEXT,
    is_markdown BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    updated_at  TIMESTAMP WITH TIME ZONE
        NOT NULL
        DEFAULT current_timestamp,
    CONSTRAINT updated_after_created CHECK (updated_at >= created_at)
);

-- Update the `updated_at` column when the ui_element is changed.
DROP TRIGGER IF EXISTS tg_ui_element_update_timestamps ON ui_element;
CREATE TRIGGER tg_ui_element_update_timestamps
    BEFORE INSERT OR UPDATE
    ON ui_element
    FOR EACH ROW
EXECUTE PROCEDURE update_updated_at_column();
