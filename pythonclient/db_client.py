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
import requests


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


def do_ldap_search(conn, query):
    """ Search Yale LDAP for a particular netid. On the command
        line this would be something like the following:
        ldapsearch \
            -H ldaps://ad.its.yale.edu:3269 \
            -D cn=s_klj39,OU=Non-Netids,OU=Users-OU,dc=yu,dc=yale,dc=edu \
            -w $LDAP_PASS "(&(objectclass=Person)(CN=klj39))"
    """
    search_base = ""
    search_filter = "(&(objectclass=Person)({0}))".format(query)
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
    except (ldap3.core.exceptions.LDAPKeyError, ldap3.core.exceptions.LDAPCursorAttributeError) as e:
        return None


def known_as_is_redundant(known_as, name):
    if not known_as:
        return False
    if known_as.lower() in set([x.lower() for x in name.split()]):
        return True
    if " " in known_as and known_as in name:
        return True
    return False


def get_ldap_connection_from_env(env):
    try:
        ldap_host = env['LDAP_HOST']
        ldap_user = env['LDAP_USER']
        ldap_pass = env['LDAP_PASS']
    except KeyError:
        print("You must provide the following in the environment: LDAP_HOST, LDAP_USER, LDAP_PASS")
    ldap_conn = get_ldap_connection(ldap_host, ldap_user, ldap_pass)
    return ldap_conn


def email_to_netid(ldap_conn, email):
    """ Turns a Yale email address into a netid using LDAP

    Arguments:
        email {string} -- Email address for which you want netid
    """
    result = do_ldap_search(ldap_conn, "mail={0}".format(email.lower()))
    netid = ldapget(result, 'cn')
    if netid is None:
        raise Exception("No netid for email {0}".format(email))
    return netid


@database.command()
@click.pass_context
def fill_user_ldap(ctx):
    """ Fill in info from Yale LDAP for all students
    """
    conn = ctx.obj['conn']
    cur = conn.cursor()
    statement = 'SELECT netid FROM data.user'
    cur.execute(statement)
    netids = set([row[0] for row in cur.fetchall()])
    conn.commit()

    ldap_conn = get_ldap_connection_from_env(os.environ)
    for netid in netids:
        print('------------------' + netid)
        result = do_ldap_search(ldap_conn, "CN={0}".format(netid))
        if result:
            print(result)
            known_as = ldapget(result, 'knownAs') or ldapget(result, 'givenName')
            name = ldapget(result, 'displayName')
            # if known_as_is_redundant(known_as, name):
            #    known_as = None
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
@click.option('--ldap/--no-ldap', default=False)
def add_students(ctx, infile, ldap):
    """ Add students from a list of netids

        Run like `honcho run python ./db_client.py add_students filename`
    """
    users = [line.strip() for line in infile]
    do_add_students(ctx.obj["conn"], users)
    if ldap:
        ctx.invoke(fill_user_ldap)


def do_add_students(conn, users):
    """ Add a list of users. Can be email or netid

    Arguments:
        conn {database connection} -- Database connection
        users {iterable} -- emails or netids
    """
    emails = [u.strip() for u in users if "@" in u]
    netids = [u.strip() for u in users if "@" not in u]

    if emails:
        ldap_conn = get_ldap_connection_from_env(os.environ)
        email_netids = [email_to_netid(ldap_conn, e) for e in emails]
        netids.extend(email_netids)

    if netids:
        add_list_of_students(conn, netids)
    return netids


def get_students_registered_for_class(url, username, password, crn, term):
    """ Grabs the students registered for a course in a particular term
        Uses an API like
        https://boomi.som.yale.edu:9090/ws/rest/subscribers/klj39/CourseRoster/

    Arguments:
        url {string} -- API URL, e.g. 
        username {string} -- API username (http basic auth)
        password {string} -- API password (http basic auth)
        crn {string} -- CRN for the course
        term {string} -- term for the course, e.g. "201903" for fall 2019
    """
    payload = {'CRN': crn, 'TermCode': term}
    response = requests.get(url, params=payload, auth=(username, password))
    registration_info = response.json()
    students = registration_info["Course"]["roster"]["student"]
    return students


@database.command()
@click.argument('crn')
@click.argument('term')
@click.option('--ldap/--no-ldap', default=False)
@click.pass_context
def add_students_from_api(ctx, crn, term, ldap):
    """ Add students from registration API. Takes the course registration
        number which you can get from the YBB or SOM Portal. Term is something
        like 201903 for Fall of 2019.

        Run like `honcho run python ./db_client.py add_students_from_api CRN TERM`
    """
    api_url = os.environ["REGISTRATION_API_URL"]
    api_username = os.environ["REGISTRATION_API_USERNAME"]
    api_password = os.environ["REGISTRATION_API_PASSWORD"]
    students = get_students_registered_for_class(
        api_url,
        api_username,
        api_password,
        crn,
        term
    )
    netids = [student["netid"] for student in students]
    add_list_of_students(ctx.obj['conn'], netids)

    if ldap:
        ctx.invoke(fill_user_ldap)


@database.command()
@click.option('--ldap/--no-ldap', default=False)
@click.pass_context
@click.argument('student')
def add_student(ctx, student, ldap):
    """ Add a student by netid
        Run like `honcho run python ./db_client.py add_student klj12`
    """
    users = [student.strip()]
    do_add_students(ctx.obj["conn"], users)
    if ldap:
        ctx.invoke(fill_user_ldap)


def add_list_of_students(conn, students):
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

def get_column_names(cursor, table):
    """ Finds the column names for a table
    """
    cursor.execute(f"Select * FROM {table} LIMIT 0")
    return [desc[0] for desc in cursor.description]

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

    columns = get_column_names(cursor, table)
    def make_query(data_dict):
        key_candidates = data_dict.keys()
        # Only keep keys that are present in the dict
        # and also are valid columns
        keys = list(set(key_candidates) & set(columns))
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
    if len(keys) > 0:
        cursor.execute(delete_query, (keys, ))

    do_upsert(cursor, 'data.assignment_field',
              'slug, assignment_slug', all_fields)

def is_single_assignment_list(data):
    """ Check if this looks like a single assignment
    """
    return len(data) == 1 and isinstance(data, list) \
           and isinstance(data[0], list) and getattr(data[0][0], 'slug')


@database.command()
@click.pass_context
@click.argument('class_number')
@click.argument('infiles', nargs=-1, required=True, type=click.File('r'))
@click.option('--delete/--no-delete', default=False)
def update_assignments(ctx, class_number, infiles, delete):
    """ Updates all assignments in the database. This takes a YAML-formatted
        list of assignments. Any assignments in the database with slugs that are
        not in the input YAML file will be deleted. Those that exist will
        be updated. Those that are new will be added.
    """
    conn = ctx.obj['conn']
    assignments = [read_yaml(infile) for infile in infiles]

    # Support having all assignments in a single yaml file. Check
    # if we got just one file and it is a list of assignments.
    if is_single_assignment_list(assignments):
        assignments = assignments[0]

    try:
        with conn.cursor() as cur:
            if delete:
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
    if len(slugs) == 0:
        return
    query = """
        SELECT api.delete_quiz_question(quiz_id, slug)
        FROM
        data.quiz_question
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
        WITH keepers (question_slug, option_slug) AS (VALUES {0}),
        existing (id, quiz_question_id, question_slug, option_slug) AS (
            SELECT qqo.id, qq.id, qq.slug, qqo.slug FROM data.quiz_question qq
            JOIN data.quiz_question_option qqo
            ON qqo.quiz_question_id = qq.id
            WHERE qq.quiz_id=%s
        ),
        todelete AS (
            select * from
            existing LEFT OUTER JOIN keepers
            ON keepers.question_slug=existing.question_slug
            AND keepers.option_slug=existing.option_slug
            WHERE keepers.option_slug IS NULL
        )
        DELETE FROM data.quiz_question_option
        WHERE id in (SELECT id from todelete)
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

def each_is_unique(iterable):
    return len(iterable) == len(set(iterable))

def quiz_is_valid(quiz):
    """ Check to see if a quiz is valid. 
    """

    # Each slug should only appear once
    slugs = [question["slug"] for question in quiz["child:quiz_questions"]]
    if len(slugs) < 1 or not each_is_unique(slugs):
        return False

    for question in quiz["child:quiz_questions"]:
        slugs = [opt["slug"] for opt in question["child:quiz_question_options"]]
        if len(slugs) < 1 or not each_is_unique(slugs):
            return False
    return True


@database.command()
@click.pass_context
@click.argument('infile', type=click.File('r'))
@click.option('--timedelta')
def update_quiz(ctx, infile, timedelta):
    """ Updates a single quiz in the database
    """
    conn = ctx.obj['conn']
    quiz = read_yaml(infile)
    if not quiz_is_valid(quiz):
        raise Exception("invalid quiz")
    return

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
