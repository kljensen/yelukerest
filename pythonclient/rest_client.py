#!/usr/bin/env python
# -*- coding: utf-8 -*-
""" A client for Yelukereset, primarily to be used by faculty for
    bulk administration over the RESTful HTTP API.
"""
import json
import datetime
from urllib.parse import urlunsplit, urljoin
import click
import ruamel.yaml as ruamel_yaml
import requests



class DateTimeEncoder(json.JSONEncoder):
    """ Handles encoding DateTime objects
    """
    def default(self, o): # pylint: disable=E0202
        """ Checks if something is a datetime and handles output if so,
            otherwise defers to default JSON encoder.
        """
        if isinstance(o, datetime.datetime):
            return o.isoformat()
        return json.JSONEncoder.default(self, o)

@click.group()
@click.pass_context
@click.option('--hostname', default="localhost", show_default=True, envvar="YELUKEREST_CLIENT_HOSTNAME")
@click.option('--protocol', default="http", show_default=True, envvar="YELUKEREST_CLIENT_PROTOCOL")
@click.option('--port', default="", show_default=True, envvar="YELUKEREST_CLIENT_PORT")
@click.option('--path', default="/rest/", show_default=True, envvar="YELUKEREST_CLIENT_PATH")
@click.option("--jwt", show_default=True, envvar="YELUKEREST_CLIENT_JWT")
def rest(ctx, hostname, protocol, port, path, jwt):
    """ A function that groups together various commands that need to know about where
        the rest server lives.
    """
    ctx.obj['hostname'] = hostname
    ctx.obj['jwt'] = jwt
    ctx.obj['protocol'] = protocol
    ctx.obj['port'] = port
    ctx.obj['path'] = path
    ctx.obj['base_url'] = build_url(protocol, hostname, port, path)
    print(ctx.obj)


def read_yaml(filehandle):
    """ Reads a YAML file from the file system
    """

    yaml = ruamel_yaml.YAML(typ="safe", pure=True)
    data = yaml.load(filehandle)
    return data


def build_url(protocol, hostname, port, path):
    """ Returns a URL
    """
    return urlunsplit((protocol, ':'.join((hostname, port)), path, '', ''))


def get_api_path(base_url, key):
    """ Get the path for a part of the API
    """
    return urljoin(base_url, key)


def get_typical_headers(jwt):
    """ Returns headers we typically use in API requests
    """
    headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer {0}".format(jwt),
        # Get back the rows inserted/updated
        # "Prefer": "return=representation"
    }
    return headers

def parse_timedelta(td):
    h, m = map(int, td.split(":"))
    return datetime.timedelta(hours=h, minutes=m)

def load_meeting(base_url, jwt, meetings, slug, timedelta):
    """ Upserts meetings into the yelukerest app. The `timedelta`
        option is included in order to make it easy to upload 
        meeting data to two different sections of class that have
        identical content but meet at different times.
    
    Arguments:
        base_url {String} -- Base URL for the app
        jwt {String} -- JWT for authentication
        meetings {List} -- Meetings to upsert
        slug {String} -- Limits upserted meetings to this slug
        timedelta {String} -- Timedelta to add to class begins_at. Should be hh:mm format.
    """
    headers = get_typical_headers(jwt)
    meetings_to_save = list(
        nonchild(m) for m in meetings
        if (not slug or m["slug"] == slug)
    )
    if timedelta:
        td = parse_timedelta(timedelta)
        for m in meetings_to_save:
            m["begins_at"] += td

    for meeting in meetings_to_save:
        url = get_api_path(base_url, "meetings")
        query_params = {'slug': 'eq.{0}'.format(meeting["slug"])}
        try:
            response = requests.get(url, headers=headers, params=query_params)
            response.raise_for_status()
        except requests.exceptions.RequestException as err:
            # Catch all exceptions
            click.echo("ERROR speaking to API: {0}".format(err))
            raise

        if not response.json():
            do_insert = True
        else:
            do_insert = False

        if do_insert:
            # We don't have this meeting
            try:
                click.echo(
                    'Trying to INSERT new meeting for slug: {0}'.format(meeting["slug"]))
                data = json.dumps(nonchild(meeting), cls=DateTimeEncoder)
                response = requests.post(url, headers=headers, data=data)
                response.raise_for_status()
            except requests.exceptions.RequestException as err:
                # Catch all exceptions
                click.echo("ERROR inserting meeting via API: {0}".format(err))
                click.echo(response.json())
                raise
        else:
            # We already have this meeting and we're going to update
            # its values.
            try:
                click.echo(
                    'Trying to UPDATE meeting for slug: {0}'.format(meeting["slug"]))
                data = json.dumps(nonchild(meeting), cls=DateTimeEncoder)
                response = requests.patch(
                    url, headers=headers, data=data, params=query_params)
                response.raise_for_status()
            except requests.exceptions.RequestException as err:
                # Catch all exceptions
                click.echo("ERROR updating meeting via API: {0}".format(err))
                click.echo(response.json())
                raise



@rest.command()
@click.pass_context
@click.argument('yaml_file', type=click.File('r'))
@click.option('--slug')
@click.option('--timedelta')
def update_meetings(ctx, yaml_file, slug, timedelta):
    """ Reads meetings from a YAML file and uploads them
    """
    meetings = read_yaml(yaml_file)
    load_meeting(ctx.obj["base_url"], ctx.obj["jwt"], meetings, slug, timedelta)


def fill_quiz_replace_fields(base_url, quiz):
    """ Some keys will be like 'replace:meetings.slug:id:meeting_id', which 
        means we should use the current value to seach meetings.slugs, take
        the first result's `id` and make that the value of the `meeting_id`
        key.
    """
    for k, v in quiz.items():
        if k.startswith('replace:'):
            (_, model_field, source_key, dest_key)  = k.split(":")
            (model, field) = model_field.split(".")
            response = requests.get(
                get_api_path(base_url, model),
                params={field: 'eq.{0}'.format(v)}
            )
            del quiz[k]
            try:
                quiz[dest_key] = response.json()[0][source_key]
            except IndexError:
                click.echo("Error filling {0} for {1} with {2}".format(dest_key, source_key, v))
                raise
    return quiz

def nonchild(d):
    """ Returns a copy of a dictionary where any key prefixed with "child:"
        is removed.
    """
    return {k:v for k,v in d.items() if not k.startswith('child:')}

def insert_quiz(base_url, jwt, quiz):
    """ Loads a quiz into the database
    """
    quiz = fill_quiz_replace_fields(base_url, quiz)
    quiz_to_save = nonchild(quiz)

    if 'meeting_id' not in quiz:
        raise Exception("Quizzes require meeting_ids before they can be saved")

    headers = get_typical_headers(jwt)
    # Delete any quiz for this meeting
    response = requests.delete(
        get_api_path(base_url, "quizzes"),
        params={"meeting_id": "eq.{0}".format(quiz_to_save["meeting_id"])},
        headers=headers
    )
    response.raise_for_status()

    post_headers = get_typical_headers(jwt)
    post_headers["Prefer"] = "return=representation"
    response = requests.post(
        get_api_path(base_url, "quizzes"),
        json=quiz_to_save,
        headers=post_headers
    )
    quiz_id = response.json()[0]["id"]
    return insert_quiz_questions(base_url, jwt, quiz_id, quiz['child:quiz_questions'])


def insert_quiz_questions(base_url, jwt, quiz_id, questions):
    """ Inserts questions for a quiz
    """
    num_options = 0
    # A this point, all quizzes should have been erased for the particular
    # meeting and that cascaded down to questions.
    post_headers = get_typical_headers(jwt)
    post_headers["Prefer"] = "return=representation"
    i=0
    for question in questions:
        question_to_save = nonchild(question)
        question_to_save["quiz_id"] = quiz_id
        response = requests.post(
            get_api_path(base_url, "quiz_questions"),
            json=question_to_save,
            headers=post_headers
        )
        quiz_question_id = response.json()[0]["id"]
        num_options += insert_quiz_question_options(
            base_url,
            jwt,
            quiz_id,
            quiz_question_id,
            question["child:quiz_question_options"]
        )
        i+=1
    return (i, num_options)

def insert_quiz_question_options(base_url, jwt, quiz_id, quiz_question_id, options):
    """ Inserts options for a quiz question
    """
    # A this point, all quizzes should have been erased for the particular
    # meeting and that cascaded down to options.
    post_headers = get_typical_headers(jwt)
    post_headers["Prefer"] = "return=representation"
    i = 0
    for option in options:
        option_to_save = nonchild(option)
        option_to_save["quiz_id"] = quiz_id
        option_to_save["quiz_question_id"] = quiz_question_id
        requests.post(
            get_api_path(base_url, "quiz_question_options"),
            json=option_to_save,
            headers=post_headers
        )
        i+=1
    return i


@rest.command()
@click.pass_context
@click.argument('yaml_file', type=click.File('r'))
def nukeload_quizzes(ctx, yaml_file):
    """ Nukes existing quizzes and loads new ones for meetings
    """
    quizzes = read_yaml(yaml_file)
    totals = {
        "quizzes": 0,
        "quiz_questions": 0,
        "quiz_question_options": 0
    }
    for quiz in quizzes:
        (num_questions, num_options) = insert_quiz(ctx.obj["base_url"], ctx.obj["jwt"], quiz)
        totals["quizzes"] += 1
        totals["quiz_question_options"] += num_options
        totals["quiz_questions"] += num_questions
    click.echo("Done and inserted the following: {0}".format(totals))



def delete_meeting_for_slug(base_url, jwt, slug, delete_all=False):
    """ Deletes a meeting with a particular slug. Deletes all meetings
        if `slug` is None and `delete_all` is True.
    """
    headers = get_typical_headers(jwt)

    # Belt and suspenders
    if delete_all is True and not slug:
        query_params = {}
    else:
        query_params = {'slug': 'eq.{0}'.format(slug)}
    url = get_api_path(base_url, "meetings")
    try:
        response = requests.delete(url, headers=headers, params=query_params)
        response.raise_for_status()
    except requests.exceptions.RequestException as err:
        # Catch all exceptions
        click.echo("ERROR speaking to API: {0}".format(err))
        raise


@rest.command()
@click.pass_context
@click.argument('slug')
# @click.option('--all', 'do_all', default=False)
def delete_meeting(ctx, slug):
    """ Deletes a meeting by slug
    """
    base_url = ctx.obj["base_url"]
    jwt = ctx.obj["jwt"]
    delete_meeting_for_slug(base_url, jwt, slug)


@rest.command()
@click.pass_context
@click.option('--really/--not-really', default=False)
def delete_all_meetings(ctx, really):
    """ Deletes a meeting by slug
    """
    base_url = ctx.obj["base_url"]
    jwt = ctx.obj["jwt"]
    if really is not True:
        click.echo("No deleting all messages because --all flag absent")
    delete_meeting_for_slug(base_url, jwt, None, delete_all=really)



def assignment_exists(base_url, jwt, slug):
    """ Checks if an assignment exists
    """
    headers = get_typical_headers(jwt)
    query_params = {'slug': 'eq.{0}'.format(slug)}
    url = get_api_path(base_url, "assignments")
    response = requests.get(url, headers=headers, params=query_params)
    response.raise_for_status()
    print(response.json())
    return (len(response.json()) != 0)


def nukeload_assignment_field(base_url, jwt, slug, field_data):
    """ Nukes fields of an assignment and uploads new ones. Careful
        with this, because it will delete all assignment field submission
        via cascade!
    """
    url = get_api_path(base_url, "assignment_fields")
    headers = get_typical_headers(jwt)
    response = requests.post(url, headers=headers, json=field_data)
    response.raise_for_status()



def load_assignment(base_url, jwt, ass_data):
    """ Load an assignment's data using either post or patch
    """

    # Check if this assignment exists
    slug = ass_data['slug']
    exists = assignment_exists(base_url, jwt, slug)

    # If it does, PATCH, else POST
    if exists:
        http_call = requests.patch
        query_params = {'slug': 'eq.{0}'.format(slug)}
    else:
        http_call = requests.post
        query_params = None
    url = get_api_path(base_url, "assignments")
    data = json.dumps(nonchild(ass_data), cls=DateTimeEncoder)
    headers = get_typical_headers(jwt)
    headers['Content-Type'] = 'application/json'
    response = http_call(url, headers=headers, data=data, params=query_params)

    # Delete the fields for this assignment
    fields = ass_data.get('child:assignment_fields', [])
    if fields:
        url = get_api_path(base_url, "assignment_fields")
        query_params = {'assignment_slug': 'eq.{0}'.format(slug)}
        headers = get_typical_headers(jwt)
        response = requests.delete(url, headers=headers, params=query_params)
        response.raise_for_status()

    for field in fields:
        nukeload_assignment_field(base_url, jwt, slug, field)


@rest.command()
@click.pass_context
@click.argument('yaml_file', type=click.File('r'))
def nukeload_assignments(ctx, yaml_file):
    """ Nukes existing assignments and loads new ones
    """
    base_url = ctx.obj["base_url"]
    jwt = ctx.obj["jwt"]
    assignments = read_yaml(yaml_file)
    for assignment in  assignments:
        load_assignment(base_url, jwt, assignment)

if __name__ == "__main__":
    rest(obj={}) # pylint: disable=E1123,E1120
