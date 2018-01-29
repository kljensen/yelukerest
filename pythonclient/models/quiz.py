""" Models relating to quizzes
"""
from operator import attrgetter
from itertools import groupby
from psycopg2.extras import NamedTupleCursor


def get_nt_cursor(conn):
    """ Get a database cursor that will allow us to get
        result rows as namedtuples
    """
    return conn.cursor(cursor_factory=NamedTupleCursor)

def do_execute(conn, statement, params):
    """ Execute a statement and return results
    """
    cur = get_nt_cursor(conn)
    cur.execute(statement, params)
    results = cur.fetchall()
    conn.commit()
    return results

def get_submissions(conn, quiz_id):
    """ Grab submissions for a quiz
    """
    statement = 'SELECT * FROM data.quiz_submission WHERE quiz_id = %s'
    return do_execute(conn, statement, (quiz_id,))

def get_answers(conn, quiz_id, submission_user_id):
    """ Retreives answers for a particular submission
    """
    statement = """SELECT
                    qqo.id as id,
                    qqo.quiz_id as quiz_id,
                    qqo.quiz_question_id,
                    qqo.body,
                    qqo.is_correct,
                    qa.user_id,
                    (qa.user_id IS NOT NULL) as is_selected
                FROM
                    data.quiz_question_option AS qqo
                LEFT OUTER JOIN
                    (SELECT * FROM data.quiz_answer WHERE user_id=%s) as qa
                ON
                    (qa.quiz_question_option_id = qqo.id)
                WHERE 
                    qqo.quiz_id = %s
                ORDER BY 
                    quiz_question_id
    """
    result = do_execute(conn, statement, (submission_user_id, quiz_id))
    return result

def upsert_grade(conn, quiz_id, user_id, points):
    """ Upsert a quiz grade
    """
    statement = """
        INSERT INTO data.quiz_grade (quiz_id, user_id, points)
        VALUES (%s, %s, %s)
        ON CONFLICT (quiz_id, user_id)
        DO UPDATE SET points = %s
        WHERE quiz_grade.quiz_id=%s AND quiz_grade.user_id=%s
        RETURNING *
    """
    do_execute(conn, statement, (quiz_id, user_id, points, points, quiz_id, user_id))


def grade_submission(conn, quiz, submission):
    """ Grade a single quiz
    """

    def chose_correctly(answer):
        """ If the answer is correct is should be selected,
            if not, not.
        """
        return (answer.is_correct and answer.is_selected) \
            or (not answer.is_correct and not answer.is_selected)

    answers = get_answers(conn, submission.quiz_id, submission.user_id)
    num_correct = 0
    num_questions = 0

    # Iterate by
    for _, choices in groupby(answers, attrgetter('quiz_question_id')):
        is_correct = all(chose_correctly(choice) for choice in choices)
        if is_correct:
            num_correct += 1
        num_questions += 1

    points = quiz.points_possible * float(num_correct) / float(num_questions)
    print(points)
    upsert_grade(conn, quiz.id, submission.user_id, points)


def get_question_options(conn, quiz_id):
    """ Retrieve all quiz question options for a quiz.
    """
    statement = """
        SELECT * FROM data.quiz_question_option WHERE quiz_id = %s ORDER BY quiz_question_id
    """
    return do_execute(conn, statement, (quiz_id,))

def get_quiz(conn, quiz_id):
    """ Get a quiz by id
    """
    statement = 'SELECT * FROM data.quiz WHERE id = %s'
    return do_execute(conn, statement, (quiz_id,))[0]


def grade(conn, quiz_id):
    """ Grades quiz
    """
    quiz = get_quiz(conn, quiz_id)
    submissions = get_submissions(conn, quiz_id)
    for submission in submissions:
        grade_submission(conn, quiz, submission)
        