\echo # filling table data.ui_element (5)
COPY data.ui_element (key,body,is_markdown) FROM STDIN (ENCODING 'utf-8', FREEZE ON);
course-name	Intro to Awesome	FALSE
course-number	MGT101x	FALSE
staff	[Kyle Jensen](http://som.yale.edu/jensen)	TRUE
home	Welcome to MGT101.\n\n- [Course site](https://www.example.test)\n- Office hours: Fridays, 2-4pm	TRUE
about	MGT101 is a sample course for development.\nQuestions go to staff@example.test.	FALSE
\.

ANALYZE data.ui_element;
