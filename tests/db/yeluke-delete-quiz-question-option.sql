begin;
select plan(8);


SELECT has_function(
    'api',
    'delete_quiz_question_option',
    ARRAY[ 'int', 'text', 'text' ],
    'Function api.delete_quiz_question_option(int, text) should exist'
);

SELECT function_privs_are(
    'api', 'delete_quiz_question_option', ARRAY['int', 'text', 'text'], 'student', ARRAY[]::text[],
    'Students should have no privileges on api.delete_quiz_question_option(int, text)'
);

SELECT set_eq(
    $$SELECT count(*) FROM data.quiz_question_option where quiz_id = 1 AND quiz_question_id=1 AND slug='n-h'$$,
    ARRAY[1],
    'n-h quiz question option for quiz 1 / question 1 should exist before deletion'
);

SELECT results_eq(
    $$SELECT api.delete_quiz_question_option(1, 'yale', 'n-h')$$,
    $$VALUES ((2, 1))$$,
    'delete_quiz_question_option should delete two answers and one quiz question option'
);

SELECT set_eq(
    $$SELECT count(*) FROM data.quiz_question_option where quiz_id = 1 AND quiz_question_id=1 AND slug='n-h'$$,
    ARRAY[0],
    'n-h quiz question option for quiz 1 / question 1 should have been deleted'
);

SELECT set_eq(
    $$SELECT count(*) FROM data.quiz_question_option where quiz_id = 2 AND quiz_question_id=4 AND slug='prov1'$$,
    ARRAY[1],
    'prov1 quiz question option for quiz 2 / question 4 should exist before deletion'
);

SELECT results_eq(
    $$SELECT api.delete_quiz_question_option(2, 'brown', 'prov1')$$,
    $$VALUES ((0, 1))$$,
    'delete_quiz_question_option should delete an unanswered quiz question option'
);

SELECT set_eq(
    $$SELECT count(*) FROM data.quiz_question_option where quiz_id = 2 AND quiz_question_id=4 AND slug='prov1'$$,
    ARRAY[0],
    'prov1 quiz question option for quiz 2 / question 4 should have been deleted'
);




select * from finish();
rollback;
