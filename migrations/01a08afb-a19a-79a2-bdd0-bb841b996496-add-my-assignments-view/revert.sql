-- The view is the whole migration; nothing else was touched.
DROP VIEW api.my_assignments
; NOTIFY pgrst, 'reload schema'
