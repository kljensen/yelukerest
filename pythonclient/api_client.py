#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""HTTP API client for Yelukerest admin operations.

This client talks to the PostgREST `api` schema. Keep direct database ETL in
`db_client.py` until each workflow has a supported API replacement.
"""

import csv
import datetime
import json
import sys
from urllib.parse import urljoin

import click
import requests
import ruamel.yaml as ruamel_yaml
from jinja2 import Template
from yaml_text import normalize_text_values


DEFAULT_BASE_URL = "https://localhost"
DEFAULT_TIMEOUT_SECONDS = 30
DEFAULT_PAGE_SIZE = 1000

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


USER_COLUMNS = (
    "id",
    "netid",
    "name",
    "lastname",
    "known_as",
    "nickname",
    "email",
    "team_nickname",
    "role",
)

# `netid`, `email`, and `nickname` are `UNIQUE NOT NULL` on `data.user`, so each
# one identifies at most one person. `name` and `team_nickname` do not, which is
# exactly why they are searchable but not resolvable.
USER_LOOKUP_FIELDS = ("netid", "email", "nickname")
USER_SEARCH_FIELDS = ("name", "email", "netid", "nickname", "team_nickname")

USER_ROLES = ("student", "faculty", "ta", "observer")

SUBMISSION_COLUMNS = (
    "assignment_slug",
    "is_team",
    "submission_id",
    "team_nickname",
    "netid",
    "name",
    "email",
    "nickname",
    "submitter_netid",
    "field_slug",
    "body",
    "submitted_at",
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
    """Read one page of a table or view, unpaged.

    Authenticated by default; `AUTH_NONE` reads as `anonymous`. Use this only
    for reads that cannot exceed one page -- `api.platform_version` is a
    single-row metadata view -- because PostgREST caps a larger result silently.
    Anything that returns a collection must use `get_all_rest`.
    """
    response = request(
        config,
        "GET",
        rest_url(config["base_url"], path),
        label=path,
        auth=auth,
        params=params,
    )
    return response.json()


def content_range_total(response, label):
    """Read the row total PostgREST reports in its `Content-Range` header.

    Raises rather than guessing. Without a total there is no way to tell a
    complete response from a capped one, and guessing wrong here means quietly
    returning a short file.
    """
    header = response.headers.get("Content-Range", "")
    total = header.rsplit("/", 1)[-1].strip() if "/" in header else ""
    if not total.isdigit():
        raise click.ClickException(
            f"{label}: PostgREST reported no usable row total "
            f"(Content-Range: {header or 'missing'}), so a truncated response "
            "cannot be told apart from a complete one. Refusing to return a "
            "result that may be incomplete."
        )
    return int(total)


def get_all_rest(config, path, order, params=None, page_size=DEFAULT_PAGE_SIZE):
    """Read every row of a table or view, paging past PostgREST's row limit.

    PostgREST caps a response at `db-max-rows` (`PGRST_DB_MAX_ROWS` in
    `docker-compose.base.yaml`) and reports the cap only in `Content-Range`. A
    single GET therefore returns a short result with a 200 status and no
    warning, which for a grade export is the worst possible failure: a truncated
    export looks exactly like a complete one, and someone grades from it.

    So every collection read pages to the server's reported total, and refuses
    to return a partial result it cannot prove is whole.

    ``order`` is required, not optional. `limit`/`offset` paging over an
    unordered result may skip or repeat rows, so the caller must name an
    ordering that ends in a unique column.
    """
    query = dict(params or {})
    query["order"] = order
    url = rest_url(config["base_url"], path)
    rows = []
    total = None

    while True:
        headers = {
            "Range-Unit": "items",
            "Range": f"{len(rows)}-{len(rows) + page_size - 1}",
        }
        if total is None:
            headers["Prefer"] = "count=exact"

        response = request(
            config, "GET", url, label=path, headers=headers, params=query
        )
        page = response.json()
        if total is None:
            total = content_range_total(response, path)
        rows.extend(page)

        if len(rows) >= total:
            return rows
        if not page:
            raise click.ClickException(
                f"{path}: PostgREST reported {total} rows but stopped returning "
                f"them after {len(rows)}. Refusing to return an incomplete result."
            )


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


def quote_filter_value(value):
    """Double-quote a value for a PostgREST filter list.

    Commas, parentheses, and dots are syntax inside `in.(…)` and `or=(…)`, so
    every value goes in quotes rather than being pasted in raw.
    """
    escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def in_filter(values):
    """Build a PostgREST `in.(…)` filter over a non-empty collection."""
    return "in.({})".format(",".join(quote_filter_value(value) for value in values))


def substring_match_filter(term, columns):
    """Build a PostgREST `or=(…)` filter matching `term` anywhere in any column."""
    clauses = ",".join(
        f"{column}.ilike.{quote_filter_value(f'*{term}*')}" for column in columns
    )
    return f"({clauses})"


def csv_value(value):
    """Render a JSON scalar for a CSV cell."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return value


def emit_rows(rows, columns, output_format):
    """Print result rows as indented JSON or as CSV with a header row."""
    if output_format == "csv":
        writer = csv.DictWriter(sys.stdout, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({key: csv_value(row.get(key)) for key in columns})
        return
    click.echo(json.dumps(rows, indent=2, sort_keys=True))


format_option = click.option(
    "--format",
    "output_format",
    type=click.Choice(["json", "csv"]),
    default="json",
    show_default=True,
    help="Output format.",
)

role_option = click.option(
    "--role",
    type=click.Choice(USER_ROLES + ("all",)),
    default="student",
    show_default=True,
    help="Limit to users with this role.",
)


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


@api.command("roster")
@role_option
@format_option
@click.pass_context
def roster(ctx, role, output_format):
    """List course users, students by default, ordered by netid."""
    params = {"select": ",".join(USER_COLUMNS)}
    if role != "all":
        params["role"] = f"eq.{role}"
    # `netid` is UNIQUE NOT NULL, so it is a stable paging order on its own.
    users = get_all_rest(ctx.obj, "users", "netid.asc", params=params)
    emit_rows(users, USER_COLUMNS, output_format)


@api.command("find-user")
@click.argument("field", type=click.Choice(USER_LOOKUP_FIELDS))
@click.argument("value")
@format_option
@click.pass_context
def find_user(ctx, field, value, output_format):
    """Resolve exactly one user by an exact match on one named field.

    The caller names the field on purpose. The clause this replaces matched
    `email` OR `netid` OR `nickname` at once, so a value that happened to look
    like someone else's netid silently resolved to the wrong person.
    """
    # `clean_user_fields()` lowercases all three of these columns on write, so a
    # caller pasting a mixed-case netid must still match.
    wanted = value.strip().lower()
    # Paged even though all three lookup columns are UNIQUE and cannot return a
    # second row today. The multiple-match check below is only as trustworthy as
    # the read under it, and "the schema makes truncation impossible here" is
    # exactly the kind of assumption that stops being true quietly.
    matches = get_all_rest(
        ctx.obj,
        "users",
        "id.asc",
        params={"select": ",".join(USER_COLUMNS), field: f"eq.{wanted}"},
    )

    if not matches:
        raise click.ClickException(f"No user has {field} '{wanted}'.")
    if len(matches) > 1:
        netids = ", ".join(sorted(str(match.get("netid")) for match in matches))
        raise click.ClickException(
            f"{len(matches)} users have {field} '{wanted}': {netids}. "
            "This command resolves exactly one user and will not guess."
        )

    if output_format == "csv":
        emit_rows(matches, USER_COLUMNS, output_format)
        return
    click.echo(json.dumps(matches[0], indent=2, sort_keys=True))


@api.command("search-users")
@click.argument("term")
@role_option
@format_option
@click.pass_context
def search_users(ctx, term, role, output_format):
    """Find users whose name, email, netid, nickname, or team contains TERM."""
    needle = term.strip()
    if not needle:
        raise click.ClickException("TERM is empty; use `roster --role all` to list everyone.")
    params = {
        "select": ",".join(USER_COLUMNS),
        "or": substring_match_filter(needle, USER_SEARCH_FIELDS),
    }
    if role != "all":
        params["role"] = f"eq.{role}"
    users = get_all_rest(ctx.obj, "users", "netid.asc", params=params)
    emit_rows(users, USER_COLUMNS, output_format)


def fetch_exported_assignments(config, assignment_slugs, include_drafts):
    """Read the assignments an export covers, refusing slugs that do not exist."""
    params = {"select": "slug,is_draft,closed_at"}
    if not include_drafts:
        params["is_draft"] = "eq.false"
    if assignment_slugs:
        params["slug"] = in_filter(assignment_slugs)

    # `closed_at` repeats across assignments, so the order ends in `slug`, the
    # primary key, to make the paging walk deterministic.
    assignments = get_all_rest(
        config, "assignments", "closed_at.asc,slug.asc", params=params
    )

    missing = sorted(set(assignment_slugs) - {row["slug"] for row in assignments})
    if missing:
        hint = "" if include_drafts else " Draft assignments need --include-drafts."
        raise click.ClickException(
            f"Unknown assignment slug(s): {', '.join(missing)}.{hint}"
        )
    return assignments


def submission_export_row(submission, field_submission, users_by_id):
    """Flatten one submitted field into an export row."""
    owner = users_by_id.get(submission.get("user_id")) or {}
    submitter = users_by_id.get(submission.get("submitter_user_id")) or {}
    return {
        "assignment_slug": submission["assignment_slug"],
        "is_team": submission["is_team"],
        "submission_id": submission["id"],
        "team_nickname": submission.get("team_nickname"),
        "netid": owner.get("netid"),
        "name": owner.get("name"),
        "email": owner.get("email"),
        "nickname": owner.get("nickname"),
        "submitter_netid": submitter.get("netid"),
        "field_slug": field_submission["assignment_field_slug"],
        "body": field_submission["body"],
        "submitted_at": field_submission["updated_at"],
    }


def collect_submission_rows(config, assignment_slugs, include_drafts, include_non_students):
    """Join assignments, submissions, submitted fields, and users into export rows."""
    assignments = fetch_exported_assignments(config, assignment_slugs, include_drafts)
    if not assignments:
        return []
    assignment_order = {row["slug"]: index for index, row in enumerate(assignments)}

    submissions = get_all_rest(
        config,
        "assignment_submissions",
        "id.asc",
        params={
            "select": "id,assignment_slug,is_team,user_id,team_nickname,submitter_user_id",
            "assignment_slug": in_filter(list(assignment_order)),
        },
    )
    if not submissions:
        return []

    users_by_id = {
        user["id"]: user
        for user in get_all_rest(
            config,
            "users",
            "id.asc",
            params={"select": "id,netid,name,email,nickname,role"},
        )
    }

    def is_exported(submission):
        if submission["assignment_slug"] not in assignment_order:
            return False
        if submission["is_team"] or include_non_students:
            return True
        owner = users_by_id.get(submission.get("user_id")) or {}
        return owner.get("role") == "student"

    exported = {
        submission["id"]: submission
        for submission in submissions
        if is_exported(submission)
    }
    if not exported:
        return []

    # The primary key is (assignment_submission_id, assignment_field_slug), so
    # ordering on both makes the paging walk deterministic.
    field_submissions = get_all_rest(
        config,
        "assignment_field_submissions",
        "assignment_submission_id.asc,assignment_field_slug.asc",
        params={
            "select": "assignment_submission_id,assignment_field_slug,body,updated_at",
            "assignment_submission_id": in_filter(list(exported)),
        },
    )

    rows = [
        submission_export_row(
            exported[field_submission["assignment_submission_id"]],
            field_submission,
            users_by_id,
        )
        for field_submission in field_submissions
        if field_submission["assignment_submission_id"] in exported
    ]
    rows.sort(
        key=lambda row: (
            assignment_order[row["assignment_slug"]],
            row["team_nickname"] or row["netid"] or "",
            row["submission_id"],
            row["field_slug"],
        )
    )
    return rows


@api.command("export-submissions")
@click.option(
    "--assignment",
    "assignment_slugs",
    multiple=True,
    help="Limit to this assignment slug. Repeatable.",
)
@click.option(
    "--include-drafts",
    is_flag=True,
    help="Also export submissions to draft assignments.",
)
@click.option(
    "--include-non-students",
    is_flag=True,
    help="Also export individual submissions owned by non-students.",
)
@format_option
@click.pass_context
def export_submissions(
    ctx, assignment_slugs, include_drafts, include_non_students, output_format
):
    """Export submitted assignment answers, one row per submitted field.

    The export is submission-centric: a team submission is one act by one team
    and appears once, carrying its `team_nickname` and the netid of whoever
    submitted it. It is deliberately not fanned out to team members, because the
    only membership this API can see is each user's *current* `team_nickname`,
    which is wrong for anyone who changed teams after submitting.

    Assignments with no submission produce no rows. "Who has not submitted" is a
    different question; answer it against `roster`, so that a blank cell here
    always means an unanswered field rather than a missing person.
    """
    rows = collect_submission_rows(
        ctx.obj, assignment_slugs, include_drafts, include_non_students
    )
    emit_rows(rows, SUBMISSION_COLUMNS, output_format)


if __name__ == "__main__":
    # pylint: disable=unexpected-keyword-arg, no-value-for-parameter
    api(obj={})
