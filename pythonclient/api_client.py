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


def rest_url(base_url, path):
    """Build a PostgREST table/view URL from a deployment base URL."""
    return urljoin(base_url.rstrip("/") + "/", f"rest/{path.lstrip('/')}")


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


AUTH_REQUIRED = "required"
AUTH_NONE = "none"


def request(config, method, url, label, auth=AUTH_REQUIRED, headers=None, **kwargs):
    """Issue a request to PostgREST, with auth, transport settings, and error mapping.

    Every call into the deployment goes through here so that the bearer token,
    timeout, TLS verification, and HTTP-error-to-ClickException translation are
    defined exactly once.

    ``auth`` is deliberately not a boolean, because "does this need a token" and
    "should this send a token" are different questions. ``AUTH_NONE`` sends no
    credentials at all, even when one is configured: PostgREST validates any token
    it is given, so an expired or wrong-deployment token would turn an endpoint
    that anonymous users can read into a 401. The compatibility preflight has to
    keep answering precisely when credentials are broken, since diagnosing that is
    what it is for.
    """
    jwt = config.get("jwt")
    if auth == AUTH_REQUIRED and not jwt:
        raise click.ClickException("YELUKEREST_CLIENT_JWT or --jwt is required")

    request_headers = {"Accept": "application/json"}
    if auth == AUTH_REQUIRED:
        request_headers["Authorization"] = f"Bearer {jwt}"
    if headers:
        request_headers.update(headers)

    response = config["session"].request(
        method,
        url,
        headers=request_headers,
        timeout=config["timeout"],
        verify=config["verify_tls"],
        **kwargs,
    )
    try:
        response.raise_for_status()
    except requests.HTTPError as exc:
        raise click.ClickException(
            f"{label} failed with HTTP {response.status_code}: {response.text}"
        ) from exc
    return response


def post_rpc(config, function_name, payload):
    response = request(
        config,
        "POST",
        rpc_url(config["base_url"], function_name),
        label=function_name,
        headers={"Content-Type": "application/json"},
        json=json_ready(payload),
    )
    return response.json()


def get_rest(config, path, params=None, auth=AUTH_REQUIRED):
    """Read a table or view. Authenticated by default; `AUTH_NONE` reads as `anonymous`."""
    response = request(
        config,
        "GET",
        rest_url(config["base_url"], path),
        label=path,
        auth=auth,
        params=params,
    )
    return response.json()


def write_rest(config, path, rows, prefer=None, params=None):
    """Write rows to a table or view.

    Internal helper for named subcommands only. There is deliberately no
    user-facing "write arbitrary rows to an arbitrary table" command: that would
    recreate the unconstrained psql access this client exists to retire, just over
    HTTP. Every write must reach the network through a named operation whose
    payload has already been checked.
    """
    headers = {"Content-Type": "application/json"}
    if prefer:
        headers["Prefer"] = prefer
    response = request(
        config,
        "POST",
        rest_url(config["base_url"], path),
        label=path,
        headers=headers,
        json=json_ready(rows),
        params=params,
    )
    if not response.content:
        return []
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
    # Granted to `anonymous`, and it is the preflight every other command depends
    # on, so it must answer before credentials are sorted out -- and must not be
    # taken down by a stale token that is itself the thing being diagnosed.
    result = get_rest(ctx.obj, "platform_version", auth=AUTH_NONE)
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
