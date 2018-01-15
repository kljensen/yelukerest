#!/usr/bin/env python
# -*- coding: utf-8 -*-
""" A client for Yelukereset, primarily to be used by faculty for
    bulk administration connecting directly to the database.
"""
import click
import psycopg2

@click.group()
@click.pass_context
@click.argument('dburl', envvar="DATABASE_URL")
def db(ctx, dburl):
    """ A function that groups together various commands and
        passes along a database connection in the context.
    """
    conn = psycopg2.connect(dburl)
    ctx.obj['conn'] = conn

@db.command()
def sayhi():
    click.echo("hi")


if __name__ == "__main__":
    db(obj={})
