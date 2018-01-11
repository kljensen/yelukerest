#!/usr/bin/env python
# -*- coding: utf-8 -*-
""" A client for Yelukereset, primarily to be used by facutly for
    bulk administration over the RESTful HTTP API.
"""
from urllib.parse import urlunsplit, urljoin
import click
import ruamel.yaml as ruamel_yaml
import requests
# from ruamel_yaml.yaml import YAML


@click.group()
@click.pass_context
@click.option('--hostname', default="localhost", show_default=True)
@click.option('--protocol', default="http", show_default=True)
@click.option('--port', default="", show_default=True)
@click.option('--path', default="/rest/", show_default=True)
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


# @cli.command()
# @click.argument("infile", type=click.File('r'))
# @click.argument("outfile", type=click.File('w'))
# def json_to_yaml(infile, outfile):
#     """ Converts JSON to YAML
#     """
#     data = json.load(infile)
#     yaml = ruamel_yaml.YAML()
#     yaml.dump(data, outfile)

def get_api_path(base_url, key):
    """ Get the path for a part of the API
    """
    api_mount_points = {
        "meetings": 'meetings'
    }
    return urljoin(base_url, api_mount_points[key])


def get_typical_headers(jwt):
    """ Returns headers we typically use in API requests
    """
    headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer {0}".format(jwt),
        # Get back the rows inserted/updated
        "Prefer": "return=representation"
    }
    return headers


def upsert_meeting(base_url, jwt, meetings, slug):
    """ Upserts meetings into base_url
    """
    headers = get_typical_headers(jwt)
    for meeting in meetings:
        if slug and meeting["slug"] != slug:
            continue
        query_params = {'slug': 'eq.{0}'.format(meeting["slug"])}

        click.echo(
            "Checking if meeting exists for slug: {0}".format(meeting["slug"]))
        url = get_api_path(base_url, "meetings")
        try:
            response = requests.get(url, headers=headers, params=query_params)
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
                response = requests.post(url, headers=headers, json=meeting)
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
                    'Trying to UPDATE new meeting for slug: {0}'.format(meeting["slug"]))
                response = requests.patch(
                    url, headers=headers, json=meeting, params=query_params)
                response.raise_for_status()
            except requests.exceptions.RequestException as err:
                # Catch all exceptions
                click.echo("ERROR updating meeting via API: {0}".format(err))
                click.echo(response.json())
                raise

    return


@rest.command()
@click.pass_context
@click.argument('yaml_file', type=click.File('r'))
@click.option('--slug')
def update_meetings(ctx, yaml_file, slug):
    """ Reads meetings from a YAML file and uploads them
    """
    meetings = read_yaml(yaml_file)
    upsert_meeting(ctx.obj["base_url"], ctx.obj["jwt"], meetings, slug)


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


if __name__ == "__main__":
    rest(obj={})
