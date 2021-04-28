begin;
select plan(7);

-- Set the search path to include api
SELECT set_config('search_path', 'api,'||current_setting('search_path'), false);

SELECT has_function(
    'api',
    'delete_quiz_question',
    ARRAY[ 'int', 'text' ],
    'Function api.delete_quiz_question(int, text) should exist'
);

SELECT function_privs_are(
    'api', 'delete_quiz_question', ARRAY['int', 'text'], 'student', ARRAY[]::text[],
    'Students should have no privileges on api.delete_quiz_question(int, text)'
);

SELECT set_eq(
    $$SELECT count(*) FROM data.quiz_question where quiz_id = 1 AND slug='yale'$$,
    ARRAY[1],
    'yale question for quiz 1 should exist before deletion'
);

SELECT results_eq(
    $$SELECT api.delete_quiz_question(1, 'yale')$$,
    $$VALUES ((3, 2, 1))$$,
    'delete_quiz_question should delete three answers, two quiz question options, and one question'
);

SELECT set_eq(
    $$SELECT count(*) FROM data.quiz_question where quiz_id = 1 AND slug='yale'$$,
    ARRAY[0],
    'yale question should have been deleted'
);

SELECT results_eq(
    $$SELECT api.delete_quiz_question(2)$$,
    $$VALUES ((1, 2, 1))$$,
    'delete_quiz_question should delete one answer, two quiz question options, and one question'
);

SELECT set_eq(
    $$SELECT count(*) FROM data.quiz_question where quiz_id = 1 AND slug='harvard'$$,
    ARRAY[0],
    'harvard question should have been deleted'
);
select * from finish();
rollback;

