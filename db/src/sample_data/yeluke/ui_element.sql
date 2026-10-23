\echo # filling table data.ui_element (4)
COPY data.ui_element (key,body,is_markdown) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
course-name	Intro to Awesome	FALSE
course-number	MGT101x	FALSE
staff	[Kyle Jensen](http://som.yale.edu/jensen)	TRUE
about	MGT101 is a sample course for development.\nQuestions go to staff@example.test.	FALSE
\.

ANALYZE data.ui_element;
