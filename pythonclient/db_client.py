#!/usr/bin/env python
# -*- coding: utf-8 -*-
""" A client for Yelukereset, primarily to be used by faculty for
    bulk administration connecting directly to the database.
"""
import os
import click
import ldap3
import psycopg2
from names import get_student_nickname
from models import quiz

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


def do_ldap_search(netid):
    """ Search Yale LDAP for a particular netid
    """
    server_uri = "ldap://directory.yale.edu:389"
    search_base = "ou=People,o=yale.edu"
    search_filter = "(uid={0})".format(netid)
    attributes = "*"
    server = ldap3.Server(server_uri)
    conn = ldap3.Connection(server, auto_bind=True)
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
    conn = ctx.obj['conn']
    cur = conn.cursor()
    statement = 'SELECT netid FROM data.user'
    cur.execute(statement)
    netids = set([row[0] for row in cur.fetchall()])
    conn.commit()

    for netid in netids:
        print('------------------' + netid)
        result = do_ldap_search(netid)
        if result:
            print(result)
            known_as = ldapget(result, 'knownAs')
            name = ldapget(result, 'cn')
            if known_as_is_redundant(known_as, name):
                known_as = None
            last_name = ldapget(result, 'sn')
            email = ldapget(result, 'mail')
            organization = ldapget(result, 'o')
            print(", ".join(str(s) for s in [name, known_as, last_name, email, organization]))
            cur = conn.cursor()
            statement = 'UPDATE data.user SET known_as = %s, name = %s, email = %s, lastname = %s, organization = %s WHERE netid = %s'
            cur.execute(statement, (known_as, name, email, last_name, organization, netid))
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


if __name__ == "__main__":
     #pylint: disable=unexpected-keyword-arg, no-value-for-parameter
    database(obj={})
