\echo # filling table data.ui_element (3)
COPY data.ui_element (key,body,is_markdown) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
course-name	Intro to Awesome	FALSE
course-number	MGT656x	FALSE
staff	[Kyle Jensen](http://som.yale.edu/jensen)	TRUE
\.

ANALYZE data.ui_element;
