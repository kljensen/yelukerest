CREATE OR REPLACE VIEW assignment_grade_events AS
    SELECT * FROM data.assignment_grade_event;

ALTER VIEW assignment_grade_events OWNER TO api;

CREATE OR REPLACE VIEW quiz_grade_events AS
    SELECT * FROM data.quiz_grade_event;

ALTER VIEW quiz_grade_events OWNER TO api;

CREATE OR REPLACE VIEW grade_events AS
    SELECT * FROM data.grade_event;

ALTER VIEW grade_events OWNER TO api;
