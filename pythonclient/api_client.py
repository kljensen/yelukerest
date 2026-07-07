#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""HTTP API client for Yelukerest admin operations.

This client talks to the PostgREST `api` schema. Keep direct database ETL in
`db_client.py` until each workflow has a supported API replacement.
"""

import datetime
import json
from urllib.parse import urljoin

import click
import requests
import ruamel.yaml as ruamel_yaml
from jinja2 import Template
from yaml_text import normalize_text_values


DEFAULT_BASE_URL = "https://localhost"
DEFAULT_TIMEOUT_SECONDS = 30

MEETING_KEYS = (
    "slug",
    "title",
    "summary",
    "description",
    "begins_at",
    "duration",
    "meeting_type",
    "is_draft",
)

ASSIGNMENT_KEYS = (
    "slug",
    "title",
    "points_possible",
    "is_draft",
    "is_markdown",
    "is_team",
    "body",
    "closed_at",
)

ASSIGNMENT_FIELD_KEYS = (
    "slug",
    "label",
    "help",
    "placeholder",
    "is_url",
    "is_multiline",
    "display_order",
    "pattern",
    "example",
)


def read_yaml(filehandle):
    """Read YAML data from a file handle."""
    yaml = ruamel_yaml.YAML(typ="safe", pure=True)
    return normalize_text_values(yaml.load(filehandle))


def parse_timedelta(td):
    """Parse HH:MM into a datetime.timedelta."""
    hours, minutes = map(int, td.split(":"))
    return datetime.timedelta(hours=hours, minutes=minutes)


def rpc_url(base_url, function_name):
    """Build a PostgREST RPC URL from a deployment base URL."""
    return urljoin(base_url.rstrip("/") + "/", f"rest/rpc/{function_name}")


def render_template(value, class_number):
    if value is None or class_number is None:
        return value
    return Template(str(value)).render(class_number=class_number)


def only_keys(source, keys):
    return {key: source[key] for key in keys if key in source}


def normalize_meeting(meeting, class_number=None, time_delta=None):
    normalized = only_keys(meeting, MEETING_KEYS)
    if "description" in normalized:
        normalized["description"] = render_template(
            normalized["description"],
            class_number,
        )
    if time_delta is not None and "begins_at" in normalized:
        normalized["begins_at"] = normalized["begins_at"] + time_delta
    return normalized


def normalize_assignment(assignment, class_number=None):
    normalized = only_keys(assignment, ASSIGNMENT_KEYS)
    if "body" in normalized:
        normalized["body"] = render_template(normalized["body"], class_number)

    fields = assignment.get("fields", assignment.get("child:assignment_fields"))
    if fields is None:
        fields = []
    normalized["fields"] = [only_keys(field, ASSIGNMENT_FIELD_KEYS) for field in fields]
    return normalized


def json_ready(value):
    """Convert YAML/Python scalar values into values accepted by requests JSON."""
    if isinstance(value, dict):
        return {key: json_ready(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_ready(item) for item in value]
    if isinstance(value, tuple):
        return [json_ready(item) for item in value]
    if isinstance(value, datetime.datetime):
        return value.isoformat()
    if isinstance(value, datetime.date):
        return value.isoformat()
    if isinstance(value, datetime.time):
        return value.isoformat()
    if isinstance(value, datetime.timedelta):
        total_seconds = int(value.total_seconds())
        hours, remainder = divmod(total_seconds, 3600)
        minutes, seconds = divmod(remainder, 60)
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"
    return value


def ensure_list(value, label):
    if not isinstance(value, list):
        raise click.ClickException(f"{label} YAML must contain a list")
    if len(value) == 0:
        raise click.ClickException(f"{label} YAML must contain at least one item")
    return value


def post_rpc(config, function_name, payload):
    if not config.get("jwt"):
        raise click.ClickException("YELUKEREST_CLIENT_JWT or --jwt is required")
    url = rpc_url(config["base_url"], function_name)
    response = config["session"].post(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {config['jwt']}",
            "Content-Type": "application/json",
        },
        json=json_ready(payload),
        timeout=config["timeout"],
        verify=config["verify_tls"],
    )
    try:
        response.raise_for_status()
    except requests.HTTPError as exc:
        raise click.ClickException(
            f"{function_name} failed with HTTP {response.status_code}: {response.text}"
        ) from exc
    return response.json()


def get_rest(config, path):
    url = urljoin(config["base_url"].rstrip("/") + "/", f"rest/{path.lstrip('/')}")
    response = config["session"].get(
        url,
        headers={"Accept": "application/json"},
        timeout=config["timeout"],
        verify=config["verify_tls"],
    )
    try:
        response.raise_for_status()
    except requests.HTTPError as exc:
        raise click.ClickException(
            f"{path} failed with HTTP {response.status_code}: {response.text}"
        ) from exc
    return response.json()


@click.group(context_settings={"help_option_names": ["-h", "--help"]})
@click.option(
    "--base-url",
    envvar="YELUKEREST_BASE_URL",
    default=DEFAULT_BASE_URL,
    show_default=True,
    help="Deployment base URL, without /rest.",
)
@click.option(
    "--jwt",
    envvar="YELUKEREST_CLIENT_JWT",
    help="Faculty user JWT for PostgREST admin RPCs.",
)
@click.option(
    "--timeout",
    default=DEFAULT_TIMEOUT_SECONDS,
    show_default=True,
    help="HTTP request timeout in seconds.",
)
@click.option(
    "--verify-tls/--insecure",
    default=True,
    show_default=True,
    help="Verify TLS certificates.",
)
@click.pass_context
def api(ctx, base_url, jwt, timeout, verify_tls):
    """Call supported Yelukerest admin RPCs through PostgREST."""
    ctx.obj = {
        "base_url": base_url,
        "jwt": jwt,
        "session": requests.Session(),
        "timeout": timeout,
        "verify_tls": verify_tls,
    }


@api.command("platform-version")
@click.pass_context
def platform_version(ctx):
    """Print Yelukerest platform compatibility metadata."""
    result = get_rest(ctx.obj, "platform_version")
    click.echo(json.dumps(result, indent=2, sort_keys=True))


@api.command("sync-meetings")
@click.argument("infile", type=click.File("r"))
@click.argument("class_number")
@click.option("--timedelta", "time_delta_text", help="Offset begins_at by HH:MM.")
@click.pass_context
def sync_meetings(ctx, infile, class_number, time_delta_text):
    """Replace the meeting set from a historical meeting YAML file."""
    time_delta = parse_timedelta(time_delta_text) if time_delta_text else None
    meetings = [
        normalize_meeting(meeting, class_number, time_delta)
        for meeting in ensure_list(read_yaml(infile), "meeting")
    ]
    result = post_rpc(ctx.obj, "sync_meetings", {"p_meetings": meetings})
    click.echo(json.dumps(result, indent=2, sort_keys=True))


@api.command("sync-assignments")
@click.argument("class_number")
@click.argument("infiles", nargs=-1, required=True, type=click.File("r"))
@click.option(
    "--delete/--no-delete",
    "delete_missing",
    default=False,
    help="Delete assignments missing from the input.",
)
@click.option(
    "--dry-run/--apply",
    "dry_run",
    default=False,
    help="Return planned counts without writing.",
)
@click.pass_context
def sync_assignments(ctx, class_number, infiles, delete_missing, dry_run):
    """Sync assignment YAML files through the admin API."""
    assignments = []
    for infile in infiles:
        loaded = read_yaml(infile)
        if isinstance(loaded, list):
            assignments.extend(loaded)
        else:
            assignments.append(loaded)

    assignments = [
        normalize_assignment(assignment, class_number)
        for assignment in ensure_list(assignments, "assignment")
    ]
    result = post_rpc(
        ctx.obj,
        "sync_assignments",
        {
            "p_assignments": assignments,
            "p_delete_missing": delete_missing,
            "p_dry_run": dry_run,
        },
    )
    click.echo(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    # pylint: disable=unexpected-keyword-arg, no-value-for-parameter
    api(obj={})
