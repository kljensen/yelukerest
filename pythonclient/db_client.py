#!/usr/bin/env python
# -*- coding: utf-8 -*-
""" A client for Yelukerest, primarily to be used by faculty for
    bulk administration connecting directly to the database.
"""
import os
import click
import ldap3
import psycopg2
from names import get_student_nickname
from models import quiz
import ruamel.yaml as ruamel_yaml
import datetime
from jinja2 import Template
from functools import partial


def read_yaml(filehandle):
    """ Reads a YAML file from the file system
    """

    yaml = ruamel_yaml.YAML(typ="safe", pure=True)
    data = yaml.load(filehandle)
    return data


@click.group()
@click.pass_context
def database(ctx):
    """ A function that groups together various commands and
        passes along a database connection in the context.
    """
    try:
        dburl = os.environ['DATABASE_URL']
    except KeyError:
        raise Exception("you must provide a DATABASE_URL in the environment")
    conn = psycopg2.connect(dburl)
    ctx.obj['conn'] = conn


def get_ldap_connection(host, user, password):
    """ Returns a connection to the LDAP host
    """
    server = ldap3.Server(host)
    conn = ldap3.Connection(server, user, password, auto_bind=True)
    return conn


def do_ldap_search(conn, netid):
    """ Search Yale LDAP for a particular netid. On the command
        line this would be something like the following:
        ldapsearch \
            -H ldaps://ad.its.yale.edu:3269 \
            -D cn=s_klj39,OU=Non-Netids,OU=Users-OU,dc=yu,dc=yale,dc=edu \
            -w $LDAP_PASS "(&(objectclass=Person)(CN=klj39))"
    """
    search_base = ""
    search_filter = "(&(objectclass=Person)(CN={0}))".format(netid)
    attributes = "*"
    conn.search(search_base, search_filter, attributes=attributes)
    try:
        return conn.entries[0]
    except IndexError:
        return None


def ldapget(result, key):
    """ Get a value from the LDAP result using a key. Return None
        if the key does not exist
    """
    try:
        return str(getattr(result, key))
    except ldap3.core.exceptions.LDAPKeyError:
        return None


def known_as_is_redundant(known_as, name):
    if not known_as:
        return False
    if known_as.lower() in set([x.lower() for x in name.split()]):
        return True
    if " " in known_as and known_as in name:
        return True
    return False


@database.command()
@click.pass_context
def getuserldap(ctx):
    """ Fill in info from Yale LDAP for all students
    """
    try:
        ldap_host = os.environ['LDAP_HOST']
        ldap_user = os.environ['LDAP_USER']
        ldap_pass = os.environ['LDAP_PASS']
    except KeyError:
        print("You must provide the following in the environment: LDAP_HOST, LDAP_USER, LDAP_PASS")

    conn = ctx.obj['conn']
    cur = conn.cursor()
    statement = 'SELECT netid FROM data.user'
    cur.execute(statement)
    netids = set([row[0] for row in cur.fetchall()])
    conn.commit()

    ldap_conn = get_ldap_connection(ldap_host, ldap_user, ldap_pass)
    for netid in netids:
        print('------------------' + netid)
        result = do_ldap_search(ldap_conn, netid)
        if result:
            print(result)
            known_as = ldapget(result, 'knownAs')
            name = ldapget(result, 'displayName')
            if known_as_is_redundant(known_as, name):
                known_as = None
            last_name = ldapget(result, 'sn')
            email = ldapget(result, 'mail')
            organization = ldapget(result, 'o')
            print(", ".join(str(s)
                            for s in [name, known_as, last_name, email, organization]))
            cur = conn.cursor()
            statement = 'UPDATE data.user SET known_as = %s, name = %s, email = %s, lastname = %s, organization = %s WHERE netid = %s'
            cur.execute(statement, (known_as, name, email,
                                    last_name, organization, netid))
            conn.commit()


@database.command()
@click.pass_context
@click.argument('netid')
@click.argument('role')
@click.argument('nickname')
def adduser(ctx, netid, role, nickname):
    """ Add a user to the database

        Run like `honcho run python ./db_client.py adduser klj39 faculty short-owl`
    """
    conn = ctx.obj['conn']
    cur = conn.cursor()
    statement = 'INSERT INTO data.user (netid, role, nickname) VALUES (%s, %s, %s)'
    cur.execute(statement, (netid, role, nickname))
    conn.commit()


@database.command()
@click.pass_context
@click.argument('infile', type=click.File('r'))
def addstudents(ctx, infile):
    """ Add students from a list of netids

        Run like `honcho run python ./db_client.py addstudents filename`
    """
    users = [line.strip() for line in infile]
    conn = ctx.obj['conn']
    return addlistofstudents(conn, users)


@database.command()
@click.pass_context
@click.argument('student')
def addstudent(ctx, student):
    """ Add a student by netid
        Run like `honcho run python ./db_client.py addstudent klj12`
    """
    users = [student.strip()]
    conn = ctx.obj['conn']
    return addlistofstudents(conn, users)


def addlistofstudents(conn, students):
    """ Add a list of students

    Arguments:
        conn {sql connection} -- connection to the postgres database
        students {list} -- list of student netids, each of which a string
    """

    cur = conn.cursor()
    statement = 'SELECT nickname FROM data.user'
    cur.execute(statement)
    existing_nicknames = set([row[0] for row in cur.fetchall()])
    conn.commit()

    cur = conn.cursor()
    statement = 'SELECT netid FROM data.user'
    cur.execute(statement)
    existing_netids = set([row[0] for row in cur.fetchall()])
    conn.commit()

    for netid in students:
        if netid in existing_netids:
            continue
        tries = 0
        new_nickname = None
        while tries == 0 or new_nickname in existing_nicknames:
            new_nickname = get_student_nickname()
            tries += 1

        cur = conn.cursor()
        statement = 'INSERT INTO data.user (netid, role, nickname) VALUES (%s, %s, %s)'
        cur.execute(statement, (netid, "student", new_nickname))
        conn.commit()


@database.command()
@click.pass_context
@click.argument('quiz_id', type=click.INT)
def grade_quiz(ctx, quiz_id):
    """ Grades a quiz
    """
    conn = ctx.obj['conn']
    quiz.grade(conn, quiz_id)


@database.command()
@click.pass_context
def grade_quizzes(ctx):
    """ Grades all quizzes that are closed and not draft
    """
    conn = ctx.obj['conn']
    gradable_quiz_ids = quiz.get_gradable_quiz_ids(conn)
    for quiz_id in gradable_quiz_ids:
        quiz.grade(conn, quiz_id)


def delete_missing_meetings(cursor, slugs):
    """ Deletes all meetings that are not in a list of slugs

    Arguments:
        cursor {psycopg2 cursor} -- A database cursor
        slugs {list} -- List of meeting slugs we want to keep
    """
    query = """
        DELETE FROM data.meeting
        WHERE slug NOT IN %s;
    """
    cursor.execute(query, (tuple(slugs),))


def parse_timedelta(td):
    h, m = map(int, td.split(":"))
    return datetime.timedelta(hours=h, minutes=m)


@database.command()
@click.pass_context
@click.argument('infile', type=click.File('r'))
@click.argument('class_number')
@click.option('--timedelta')
def update_meetings(ctx, infile, class_number, timedelta):
    """ Updates all meetings in the database. This takes a YAML-formatted
        list of meetings. Any meetings in the database with slugs that are
        not in the input YAML file will be deleted. Those that exist will
        be updated. Those that are new will be added.
    """
    conn = ctx.obj['conn']
    meetings = read_yaml(infile)

    if timedelta:
        td = parse_timedelta(timedelta)
        for m in meetings:
            m["begins_at"] += td

    prepare_meeting = partial(prepare_content, class_number, 'description')

    try:
        with conn.cursor() as cur:
            print("WOOOT")
            delete_missing_meetings(cur, [m['slug'] for m in meetings])
            do_upsert(cur, "data.meeting", "slug",
                      [prepare_meeting(m) for m in meetings])
        conn.commit()
    except (Exception, psycopg2.DatabaseError) as error:
        print(error)
        conn.rollback()
    finally:
        conn.close()


def delete_missing_assignments(cursor, slugs):
    """ Deletes all assignments that are not in a list of slugs

    Arguments:
        cursor {psycopg2 cursor} -- A database cursor
        slugs {list} -- List of assignment slugs we want to keep
    """
    query = """
        DELETE FROM data.assignment
        WHERE slug NOT IN %s;
    """
    cursor.execute(query, (tuple(slugs),))


def nonchild(d):
    """ Returns a copy of a dictionary where any key prefixed with "child:"
        is removed.
    """
    return {k: v for k, v in d.items() if not k.startswith('child:')}


def do_upsert(cursor, table, conflict_condition, rows):
    """ Upserts rows.

    Arguments:
        cursor {psygopg2 cursor} -- A database cursor
        table {string} -- table in which to upsert
        conflict_condition {string} -- confict condition for UPDATE
        rows {list} -- the data to upsert, a list of dictionaries
    """
    base_query = """
        INSERT INTO {} ({})
        VALUES ({})
        ON CONFLICT ({})
        DO UPDATE
        SET {};
    """

    def make_query(assignment):
        keys = assignment.keys()
        return base_query.format(
            table,
            ','.join(keys),
            ','.join('%({})s'.format(k) for k in keys),
            conflict_condition,
            ','.join('{}=EXCLUDED.{}'.format(k, k) for k in keys)

        )
    for row in rows:
        q = make_query(row)
        cursor.execute(q, row)


def prepare_content(class_number, key, obj):
    """ Removes children and runs body of obj through jinja2.

    Arguments:
        class_number {string} -- Class number, like 656 or 660
        obj {dictionary} -- Obj, an assignment or meeting info
    """
    template = Template(obj[key])
    obj[key] = template.render(class_number=class_number)
    print(obj[key])
    return nonchild(obj)


def upsert_assignments(cursor, class_number, assignments):
    """ Upserts assignments. Each assignment may have different
        columns specified. Though, each must have a 'slug' column
        or an exception will be raised.

    Arguments:
        cursor {psygopg2 cursor} -- A database cursor
        assignments {list} -- list of assignments
    """
    prepare_assignment = partial(prepare_content, class_number, 'body')

    do_upsert(cursor, "data.assignment", "slug",
              [prepare_assignment(a) for a in assignments])

    all_fields = []
    for assignment in assignments:
        fields = assignment.get("child:assignment_fields", [])
        for field in fields:
            field["assignment_slug"] = assignment["slug"]
        all_fields.extend(fields)

    delete_query = """
        DELETE FROM data.assignment_field
        WHERE (slug, assignment_slug) NOT IN %s
    """
    keys = tuple(
        (f["slug"], f["assignment_slug"]) for f in all_fields)
    cursor.execute(delete_query, (keys, ))

    do_upsert(cursor, 'data.assignment_field',
              'slug, assignment_slug', all_fields)


@database.command()
@click.pass_context
@click.argument('class_number')
@click.argument('infile', type=click.File('r'))
def update_assignments(ctx, class_number, infile):
    """ Updates all assignments in the database. This takes a YAML-formatted
        list of assignments. Any assignments in the database with slugs that are
        not in the input YAML file will be deleted. Those that exist will
        be updated. Those that are new will be added.
    """
    conn = ctx.obj['conn']
    assignments = read_yaml(infile)

    try:
        with conn.cursor() as cur:
            delete_missing_assignments(cur, [m['slug'] for m in assignments])
            upsert_assignments(cur, class_number, assignments)
        conn.commit()
    except (Exception, psycopg2.DatabaseError) as error:
        print(error)
        conn.rollback()
        raise
    finally:
        conn.close()


def delete_missing_quiz_questions(cur, quiz_id, slugs):
    """ Deletes any questions for a quiz that do not have slugs
        in the `slugs` list.

    Arguments:
        cur {psygopg2 cursor} -- A database cursor
        quiz_id {int} -- Id for the quiz
        slugs {iterable of strings} -- List of slugs for this quiz's questions
    """
    query = """
        DELETE FROM data.quiz_question
        WHERE quiz_id=%s AND slug NOT IN %s;
    """
    cur.execute(query, (quiz_id, tuple(slugs),))


def get_quiz_id(cur, meeting_slug):
    """ Gets the id for the quiz with meeting slug equal to `meeting_slug`

    Arguments:
        cur {psygopg2 cursor} -- A database cursor
        meeting_slug {string} -- The slug for the meeting to which this quiz corresponds
    """
    cur.execute("SELECT id from data.quiz WHERE meeting_slug=%s",
                (meeting_slug,))
    quiz_id = cur.fetchone()[0]
    return quiz_id


def comma_params(x):
    """ Returns "%s,%s,%s", where there are `x` or `len(x)`
        members in the string.

    Arguments:
        x {int or iterable} -- Number of times we should do this thing

    Returns:
        [string] -- something like "%s,%s,%s,%s"
    """
    if isinstance(x, int):
        y = x
    else:
        y = len(x)
    return ",".join(["%s"]*y)


def delete_missing_quiz_question_options(cur, quiz_id, slugs):
    """ Deletes the quiz question options that ought to be deleted :)

    Arguments:
        cur {psygopg2 cursor} -- A database cursor
        quiz_id {int} -- id of the quiz to which the questions correspond
        slugs {list of two-tuples of strings} -- A list where each member is a
          tuple of quiz_question slug quiz_question_option slug.
    """
    query = """
        WITH options (question_slug, option_slug) AS (VALUES {0}),
        options_to_keep (quiz_question_id, slug) AS (
            SELECT qq.id, option_slug FROM
                options JOIN data.quiz_question qq
                ON options.question_slug = qq.slug
                WHERE qq.quiz_id = %s
        ),
        found_options AS (
            SELECT qqo.id FROM data.quiz_question_option qqo
                JOIN options_to_keep otk
                ON qqo.quiz_question_id = otk.quiz_question_id
                AND qqo.slug = otk.slug
        )
        DELETE FROM data.quiz_question_option
            WHERE id NOT IN (SELECT id FROM found_options)
    """.format(comma_params(slugs))
    try:
        cur.execute(query, slugs+(quiz_id,))
    except psycopg2.ProgrammingError as err:
        print(err)
        raise


def upsert_quiz_question_options(cur, quiz_id, option_tups):
    """ Upserts the quiz questions options. Requires some SQL-foo
        since we don't know the quiz_question_id for each option.
        Instead, we know the slug.

    Arguments:
        cur {psygopg2 cursor} -- A database cursor
        quiz_id {int} -- id of the quiz to which the questions correspond
        option_tups {iterable of tuples} -- Each tuple is (quiz_question_slug, slug, is_correct, body)
    """
    query = """
        WITH options (question_slug, slug, is_correct, body) AS (VALUES {0}),
        data_to_insert (quiz_question_id, slug, is_correct, body) AS (
            SELECT qq.id, options.slug, options.is_correct, options.body FROM
                options JOIN data.quiz_question qq
                ON options.question_slug = qq.slug
                WHERE qq.quiz_id = %s
        )
        INSERT INTO data.quiz_question_option (quiz_id, quiz_question_id, slug, is_correct, body)
            SELECT %s, quiz_question_id, slug, is_correct, body FROM data_to_insert
        ON CONFLICT (quiz_question_id, slug)
        DO UPDATE SET
            is_correct=EXCLUDED.is_correct,
            body=EXCLUDED.body
    """.format(comma_params(option_tups))
    try:
        # print(str(cur.mogrify(query, option_tups+(quiz_id,))))
        cur.execute(query, option_tups+(quiz_id, quiz_id))
    except psycopg2.ProgrammingError as err:
        print(err)
        raise


def upsert_quiz(cur, quiz):
    """ Upserts a quiz and deletes questions associated with this
        quiz that are no longer present, and quiz question options
        associated with those questions that are no longer present.
        Upserts the questions and quiz question options.

    Arguments:
        cur {psygopg2 cursor} -- A database cursor
        quiz {Object} -- The quiz info
    """
    do_upsert(cur, "data.quiz", "meeting_slug", [nonchild(quiz)])
    quiz_id = get_quiz_id(cur, quiz['meeting_slug'])

    delete_missing_quiz_questions(
        cur,
        quiz_id,
        [q['slug'] for q in quiz['child:quiz_questions']]
    )

    questions = quiz['child:quiz_questions']
    for q in questions:
        q['quiz_id'] = quiz_id

    do_upsert(
        cur,
        "data.quiz_question",
        "quiz_id, slug",
        [nonchild(qq) for qq in questions]
    )

    option_tups = tuple(
        (qq['slug'], qqo['slug'], qqo['is_correct'], qqo['body'])
        for qq in questions
        for qqo in qq['child:quiz_question_options']
    )
    option_slug_tups = tuple((x[0], x[1]) for x in option_tups)
    delete_missing_quiz_question_options(cur, quiz_id, option_slug_tups)
    upsert_quiz_question_options(cur, quiz_id, option_tups)
    # for question in quiz['child:quiz_questions']:
    #     question['quiz_id'] = quiz_id


@database.command()
@click.pass_context
@click.argument('infile', type=click.File('r'))
@click.option('--timedelta')
def update_quiz(ctx, infile, timedelta):
    """ Updates a single quiz in the database
    """
    conn = ctx.obj['conn']
    quiz = read_yaml(infile)

    # Usually I don't specify "closed_at" because
    # it is set by a database trigger to be the
    # start time of the class.
    if timedelta and "closed_at" in quiz:
        td = parse_timedelta(timedelta)
        quiz["closed_at"] += td

    try:
        with conn.cursor() as cur:
            upsert_quiz(cur, quiz)
        conn.commit()
    except (Exception, psycopg2.DatabaseError) as error:
        print(error)
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
     # pylint: disable=unexpected-keyword-arg, no-value-for-parameter
    database(obj={})
