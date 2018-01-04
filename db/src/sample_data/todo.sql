
-- 
-- fill table data.todo (6)
\echo # filling table data.todo (6)
COPY data.todo (id,todo,private,owner_id) FROM STDIN (FREEZE ON);
1	item_1	FALSE	1
2	foo	TRUE	1
3	bar	FALSE	1
4	item_4	TRUE	2
5	item_5	TRUE	2
6	item_6	FALSE	2
\.
-- 
-- restart sequences
ALTER SEQUENCE data.todo_id_seq RESTART WITH 7;
-- 
-- analyze modified tables
ANALYZE data.todo;
