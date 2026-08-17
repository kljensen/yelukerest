GRANT EXECUTE ON FUNCTION api.sync_meetings(jsonb) TO faculty;
GRANT EXECUTE ON FUNCTION api.sync_assignments(jsonb, boolean, boolean) TO faculty;
GRANT EXECUTE ON FUNCTION data.resolve_assignment_grade_import(jsonb) TO faculty;
GRANT EXECUTE ON FUNCTION api.import_assignment_grades(jsonb, boolean, boolean, text, text) TO faculty;
GRANT EXECUTE ON FUNCTION data.resolve_quiz_result_import(jsonb) TO faculty;
GRANT EXECUTE ON FUNCTION api.import_quiz_results(jsonb, boolean, boolean, text, text) TO faculty;
