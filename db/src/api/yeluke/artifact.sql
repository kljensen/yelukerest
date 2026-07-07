CREATE OR REPLACE VIEW artifacts AS
    SELECT * FROM data.artifact;

ALTER VIEW artifacts OWNER TO api;
