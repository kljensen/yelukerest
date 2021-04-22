-- If there is an `updated_at` column on the model, set it to the
-- current timestamp with timezone. This is used so that we know
-- when a row was last changed.
--
-- Function taken from https://gist.github.com/logrusorgru/82b002b8807253b2adef
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = current_timestamp;
    RETURN NEW;
END;
$$ language 'plpgsql';
