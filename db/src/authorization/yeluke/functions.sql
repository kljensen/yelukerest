GRANT EXECUTE ON FUNCTION api.sync_meetings(jsonb) TO faculty;
GRANT EXECUTE ON FUNCTION api.sync_assignments(jsonb, boolean, boolean) TO faculty;
GRANT EXECUTE ON FUNCTION api.import_assignment_grades(jsonb, boolean, boolean, text, text) TO faculty;
