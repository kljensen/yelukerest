#!/usr/bin/env python
# -*- coding: utf-8 -*-
""" A client for Yelukereset, primarily to be used by facutly for
    bulk administration over the RESTful HTTP API.
"""
from urllib.parse import urlunsplit, urljoin
import json
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
    return urljoin(base_url, api_mount_points["meetings"])


def upsert_meeting(base_url, jwt, meetings, slug):
    """ Upserts meetings into base_url
    """
    headers = {
        "Content-Type": "application/json",
        "Authorization": "Bearer {0}".format(jwt)
    }
    for meeting in meetings:
        if slug and meeting["slug"] != slug:
            continue

        click.echo(
            "Checking if meeting exists for slug: {0}".format(meeting["slug"]))
        url = get_api_path(base_url, "meetings")
        payload = {'slug': 'eq.{0}'.format(meeting["slug"])}
        try:
            response = requests.get(url, headers=headers, params=payload)
        except requests.exceptions.RequestException as err:
            # Catch all exceptions
            click.echo("ERROR speaking to API: {0}".format(err))
            raise
        print(response.text)
        if not response.json():
            do_insert = True
        else:
            do_insert = False

        if do_insert:
            try:
                click.echo(
                    'Trying to insert new meeting for slug: {0}'.format(meeting["slug"]))
                response = requests.post(url, headers=headers, json=meeting)
                response.raise_for_status()
            except requests.exceptions.RequestException as err:
                # Catch all exceptions
                click.echo("ERROR speaking to API: {0}".format(err))
                click.echo(response.json())
                raise

        try:
            click.echo(response.json())
        except:
            pass

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


if __name__ == "__main__":
    rest(obj={})
