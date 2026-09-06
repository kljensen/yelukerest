SELECT *
FROM no_plan()
; SELECT has_schema('information_schema')
; SELECT has_view('information_schema', 'routines', 'has routines information_schema.routines view')
; SELECT has_column('information_schema', 'routines', 'specific_name', 'has information_schema.routines.specific_name column')
; SELECT *
FROM finish()
