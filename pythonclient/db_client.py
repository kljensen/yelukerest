#!/usr/bin/env python
# -*- coding: utf-8 -*-
""" A client for Yelukereset, primarily to be used by faculty for
    bulk administration connecting directly to the database.
"""
import click
import os
import psycopg2
from names import get_student_nickname


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

        Run like `honcho run python ./db_client.py adduser klj39 faculty short-owl`
    """
    users = [line.strip() for line in infile]
    print(users)
    conn = ctx.obj['conn']
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

    for netid in users:
        if netid in existing_netids:
            continue
        tries = 0
        new_nickname = None
        while tries == 0 or new_nickname in existing_nicknames:
            new_nickname = get_student_nickname()
            tries += 1

        conn = ctx.obj['conn']
        cur = conn.cursor()
        statement = 'INSERT INTO data.user (netid, role, nickname) VALUES (%s, %s, %s)'
        cur.execute(statement, (netid, "student", new_nickname))
        conn.commit()


if __name__ == "__main__":
    database(obj={})
