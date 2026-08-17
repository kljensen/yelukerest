import datetime
import io
import json
import unittest

import click
from click.testing import CliRunner

import api_client


class FakeResponse:
    status_code = 200
    text = "ok"
    content = b"[]"

    def __init__(self, payload, headers=None):
        self.payload = payload
        self.headers = headers or {}

    def raise_for_status(self):
        return None

    def json(self):
        return self.payload


class FakeSession:
    """Stands in for a requests.Session.

    Everything the client sends goes through `request`, so that is the only seam
    the fake needs.
    """

    def __init__(self):
        self.calls = []

    def request(self, method, url, **kwargs):
        self.calls.append((url, kwargs))
        self.methods = getattr(self, "methods", [])
        self.methods.append(method)
        if method == "GET":
            return FakeResponse([{"admin_api_version": 5}])
        return FakeResponse(kwargs["json"])


class RoutingSession:
    """Answers GETs from a `rest` path to payload map, recording what was sent.

    Behaves like PostgREST under `db-max-rows`: it honours the `Range` header but
    never returns more than `max_rows` at a time, and always reports the true
    total in `Content-Range`. `max_rows` is what makes truncation reproducible.
    """

    def __init__(self, payloads, max_rows=1000):
        self.payloads = payloads
        self.max_rows = max_rows
        self.calls = []

    def request(self, method, url, **kwargs):
        path = url.rsplit("/rest/", 1)[-1]
        headers = kwargs.get("headers") or {}
        self.calls.append((path, kwargs.get("params") or {}, headers))

        rows = self.payloads[path]
        start, end = self._requested_range(headers, len(rows))
        page = rows[start : start + min(end - start + 1, self.max_rows)]
        last = start + len(page) - 1 if page else start
        return FakeResponse(
            page, headers={"Content-Range": f"{start}-{last}/{len(rows)}"}
        )

    @staticmethod
    def _requested_range(headers, row_count):
        wanted = headers.get("Range")
        if not wanted:
            return 0, max(row_count - 1, 0)
        first, _, last = wanted.partition("-")
        return int(first), int(last)

    def params_for(self, path):
        return [params for called, params, _ in self.calls if called == path]

    def headers_for(self, path):
        return [headers for called, _, headers in self.calls if called == path]


class NoContentRangeSession(RoutingSession):
    """A deployment whose `Content-Range` never arrives, e.g. stripped by a proxy."""

    def request(self, method, url, **kwargs):
        response = super().request(method, url, **kwargs)
        response.headers = {}
        return response


class StallingSession(RoutingSession):
    """Claims a total it then refuses to deliver, to prove the loop terminates."""

    def request(self, method, url, **kwargs):
        response = super().request(method, url, **kwargs)
        path = url.rsplit("/rest/", 1)[-1]
        response.headers = {"Content-Range": f"0-0/{len(self.payloads[path]) + 5}"}
        return response


STUDENT = {
    "id": 10,
    "netid": "aaa11",
    "name": "Ann Aardvark",
    "email": "ann@example.test",
    "nickname": "brave-otter",
    "role": "student",
}
TEAMMATE = {
    "id": 11,
    "netid": "bbb22",
    "name": "Bob Bison",
    "email": "bob@example.test",
    "nickname": "calm-heron",
    "role": "student",
}
LATE_JOINER = {
    "id": 12,
    "netid": "ccc33",
    "name": "Cy Crane",
    "email": "cy@example.test",
    "nickname": "eager-lynx",
    "role": "student",
}
PROFESSOR = {
    "id": 99,
    "netid": "ppp99",
    "name": "Pat Professor",
    "email": "pat@example.test",
    "nickname": "wise-elk",
    "role": "faculty",
}


def submission_payloads():
    """A course with one individual assignment, one team assignment, one draft."""
    return {
        "assignments": [
            {"slug": "repo", "is_draft": False, "closed_at": "2026-01-01T00:00:00Z"},
            {
                "slug": "team-project",
                "is_draft": False,
                "closed_at": "2026-02-01T00:00:00Z",
            },
        ],
        "assignment_submissions": [
            {
                "id": 1,
                "assignment_slug": "repo",
                "is_team": False,
                "user_id": 10,
                "team_nickname": None,
                "submitter_user_id": 10,
            },
            {
                "id": 2,
                "assignment_slug": "repo",
                "is_team": False,
                "user_id": 99,
                "team_nickname": None,
                "submitter_user_id": 99,
            },
            {
                "id": 3,
                "assignment_slug": "team-project",
                "is_team": True,
                "user_id": None,
                "team_nickname": "blue-team",
                "submitter_user_id": 11,
            },
        ],
        # Both TEAMMATE and LATE_JOINER are on blue-team right now.
        "users": [STUDENT, TEAMMATE, LATE_JOINER, PROFESSOR],
        "assignment_field_submissions": [
            {
                "assignment_submission_id": 1,
                "assignment_field_slug": "url",
                "body": "https://example.test/ann",
                "updated_at": "2026-01-01T00:00:00Z",
            },
            {
                "assignment_submission_id": 2,
                "assignment_field_slug": "url",
                "body": "https://example.test/pat",
                "updated_at": "2026-01-01T00:00:00Z",
            },
            {
                "assignment_submission_id": 3,
                "assignment_field_slug": "url",
                "body": "https://example.test/blue",
                "updated_at": "2026-02-01T00:00:00Z",
            },
            {
                "assignment_submission_id": 3,
                "assignment_field_slug": "notes",
                "body": "Deployed on Friday",
                "updated_at": "2026-02-01T00:00:00Z",
            },
        ],
    }


class ApiClientTest(unittest.TestCase):
    def test_rpc_url_joins_base_url_and_function_name(self):
        self.assertEqual(
            api_client.rpc_url("https://example.test/course/", "sync_meetings"),
            "https://example.test/course/rest/rpc/sync_meetings",
        )

    def test_meeting_normalization_renders_templates_and_offsets_datetimes(self):
        meeting = {
            "slug": "week-1",
            "title": "Week 1",
            "description": "Course {{ class_number }}",
            "begins_at": datetime.datetime(2026, 1, 14, 14, 0),
            "meeting_type": "office-hours",
            "ignored": "not sent",
        }

        normalized = api_client.normalize_meeting(
            meeting,
            class_number="858",
            time_delta=datetime.timedelta(hours=1, minutes=30),
        )

        self.assertEqual(normalized["description"], "Course 858")
        self.assertEqual(normalized["meeting_type"], "office-hours")
        self.assertEqual(
            normalized["begins_at"],
            datetime.datetime(2026, 1, 14, 15, 30),
        )
        self.assertNotIn("ignored", normalized)
        self.assertEqual(
            api_client.json_ready(normalized)["begins_at"],
            "2026-01-14T15:30:00",
        )

    def test_assignment_normalization_maps_child_fields_to_rpc_fields(self):
        assignment = {
            "slug": "repo",
            "title": "Repository",
            "body": "Submit for {{ class_number }}",
            "points_possible": 25,
            "question": "legacy metadata",
            "child:assignment_fields": [
                {
                    "slug": "url",
                    "label": "URL",
                    "is_url": True,
                    "extra": "not sent",
                }
            ],
        }

        normalized = api_client.normalize_assignment(assignment, class_number="858")

        self.assertEqual(normalized["body"], "Submit for 858")
        self.assertEqual(
            normalized["fields"],
            [{"slug": "url", "label": "URL", "is_url": True}],
        )
        self.assertNotIn("question", normalized)
        self.assertNotIn("child:assignment_fields", normalized)

    def test_assignment_sync_posts_normalized_rpc_payload(self):
        runner = CliRunner()
        yaml_text = """
slug: repo
title: Repository
body: Submit for {{ class_number }}
child:assignment_fields:
  - slug: url
    label: URL
    is_url: true
"""
        fake_session = FakeSession()

        with runner.isolated_filesystem():
            with open("assignment.yaml", "w", encoding="utf-8") as outfile:
                outfile.write(yaml_text)

            result = runner.invoke(
                api_client.sync_assignments,
                ["858", "assignment.yaml", "--delete", "--dry-run"],
                obj={
                    "base_url": "https://example.test",
                    "jwt": "jwt",
                    "session": fake_session,
                    "timeout": 30,
                    "verify_tls": True,
                },
            )

        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(
            fake_session.calls[0][0],
            "https://example.test/rest/rpc/sync_assignments",
        )
        payload = fake_session.calls[0][1]["json"]
        self.assertTrue(payload["p_delete_missing"])
        self.assertTrue(payload["p_dry_run"])
        self.assertEqual(
            payload["p_assignments"][0]["fields"],
            [{"slug": "url", "label": "URL", "is_url": True}],
        )
        self.assertEqual(
            fake_session.calls[0][1]["headers"]["Authorization"],
            "Bearer jwt",
        )
        self.assertEqual(json.loads(result.output), payload)

    def test_meeting_sync_requires_class_number(self):
        runner = CliRunner()

        with runner.isolated_filesystem():
            with open("meeting.yaml", "w", encoding="utf-8") as outfile:
                outfile.write("- slug: week-1\n  description: Class {{ class_number }}\n")

            result = runner.invoke(
                api_client.sync_meetings,
                ["meeting.yaml"],
                obj={
                    "base_url": "https://example.test",
                    "jwt": "jwt",
                    "session": FakeSession(),
                    "timeout": 30,
                    "verify_tls": True,
                },
            )

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("Missing argument 'CLASS_NUMBER'", result.output)

    def test_platform_version_does_not_require_jwt(self):
        runner = CliRunner()
        fake_session = FakeSession()

        result = runner.invoke(
            api_client.platform_version,
            [],
            obj={
                "base_url": "https://example.test",
                "jwt": None,
                "session": fake_session,
                "timeout": 30,
                "verify_tls": True,
            },
        )

        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(
            fake_session.calls[0][0],
            "https://example.test/rest/platform_version",
        )
        self.assertEqual(json.loads(result.output), [{"admin_api_version": 5}])

    def _config(self, jwt, session=None):
        return {
            "base_url": "https://example.test",
            "jwt": jwt,
            "session": session or FakeSession(),
            "timeout": 30,
            "verify_tls": True,
        }

    def test_rest_url_joins_base_url_and_path(self):
        self.assertEqual(
            api_client.rest_url("https://example.test/course/", "/users"),
            "https://example.test/course/rest/users",
        )

    def test_reads_send_the_bearer_token(self):
        # The bug this replaces: get_rest sent only Accept, so every read ran as
        # `anonymous` and faculty-only reads came back empty or 401'd.
        config = self._config("faculty-token")

        api_client.get_rest(config, "users")

        headers = config["session"].calls[0][1]["headers"]
        self.assertEqual(headers["Authorization"], "Bearer faculty-token")

    def test_reads_without_a_token_fail_with_a_clear_message(self):
        config = self._config(None)

        with self.assertRaises(click.ClickException) as caught:
            api_client.get_rest(config, "users")

        self.assertIn("YELUKEREST_CLIENT_JWT", caught.exception.message)
        self.assertEqual(config["session"].calls, [], "must not hit the network")

    def test_anonymous_reads_never_send_a_token_even_when_one_is_configured(self):
        # The preflight must survive a stale or wrong-deployment token, because
        # diagnosing exactly that is what it is for. PostgREST validates any token
        # it is handed, so attaching one turns an anonymous-readable view into a 401.
        config = self._config("expired-token")

        api_client.get_rest(config, "platform_version", auth=api_client.AUTH_NONE)

        headers = config["session"].calls[0][1]["headers"]
        self.assertNotIn("Authorization", headers)

    def test_anonymous_reads_omit_the_header_when_no_token_is_set(self):
        config = self._config(None)

        api_client.get_rest(config, "platform_version", auth=api_client.AUTH_NONE)

        headers = config["session"].calls[0][1]["headers"]
        self.assertNotIn("Authorization", headers)

    def test_platform_version_preflight_ignores_a_configured_token(self):
        runner = CliRunner()
        fake_session = FakeSession()

        result = runner.invoke(
            api_client.platform_version,
            [],
            obj=self._config("expired-token", session=fake_session),
        )

        self.assertEqual(result.exit_code, 0, result.output)
        self.assertNotIn("Authorization", fake_session.calls[0][1]["headers"])

    def test_http_errors_become_click_exceptions_naming_the_target(self):
        class Failing(FakeSession):
            def request(self, method, url, **kwargs):
                response = FakeResponse(None)
                response.status_code = 401
                response.text = "permission denied"
                response.raise_for_status = self._raise
                return response

            @staticmethod
            def _raise():
                raise api_client.requests.HTTPError("401")

        config = self._config("token", session=Failing())

        with self.assertRaises(click.ClickException) as caught:
            api_client.get_rest(config, "users")

        self.assertIn("users", caught.exception.message)
        self.assertIn("401", caught.exception.message)
        self.assertIn("permission denied", caught.exception.message)

    def test_writes_go_through_a_named_path_with_auth_and_prefer(self):
        config = self._config("faculty-token")

        api_client.write_rest(
            config, "users", [{"netid": "abc12"}], prefer="resolution=merge-duplicates"
        )

        url, kwargs = config["session"].calls[0]
        self.assertEqual(url, "https://example.test/rest/users")
        self.assertEqual(config["session"].methods[0], "POST")
        self.assertEqual(kwargs["headers"]["Authorization"], "Bearer faculty-token")
        self.assertEqual(kwargs["headers"]["Prefer"], "resolution=merge-duplicates")
        self.assertEqual(kwargs["json"], [{"netid": "abc12"}])

    def test_no_user_facing_command_writes_arbitrary_tables(self):
        # Guards the boundary decision in #297: writes must reach the network
        # only through named subcommands, never a generic table writer.
        command_names = set(api_client.api.commands)
        for forbidden in ("write", "insert", "post", "upsert", "write-rows"):
            self.assertNotIn(forbidden, command_names)

    def test_read_yaml_loads_lists_from_file_handles(self):
        loaded = api_client.read_yaml(io.StringIO("- slug: one\n"))
        self.assertEqual(loaded, [{"slug": "one"}])

    def test_read_yaml_coerces_text_fields_after_implicit_typing(self):
        loaded = api_client.read_yaml(
            io.StringIO(
                """
slug: 123
body: true
points_possible: 25
is_draft: false
fields:
  - slug: false
    assignment_slug: 123
    is_url: true
    display_order: 0
"""
            )
        )

        self.assertEqual(loaded["slug"], "123")
        self.assertEqual(loaded["body"], "true")
        self.assertEqual(loaded["points_possible"], 25)
        self.assertIs(loaded["is_draft"], False)
        self.assertEqual(loaded["fields"][0]["slug"], "false")
        self.assertEqual(loaded["fields"][0]["assignment_slug"], "123")
        self.assertIs(loaded["fields"][0]["is_url"], True)
        self.assertEqual(loaded["fields"][0]["display_order"], 0)


class ReadOperationTest(unittest.TestCase):
    def _run(self, command, args, payloads, session=None, max_rows=1000):
        session = session or RoutingSession(payloads, max_rows=max_rows)
        result = CliRunner().invoke(
            command,
            args,
            obj={
                "base_url": "https://example.test",
                "jwt": "faculty-token",
                "session": session,
                "timeout": 30,
                "verify_tls": True,
            },
        )
        return result, session

    def test_roster_asks_for_students_ordered_by_netid(self):
        result, session = self._run(
            api_client.roster, [], {"users": [STUDENT, TEAMMATE]}
        )

        self.assertEqual(result.exit_code, 0, result.output)
        params = session.params_for("users")[0]
        self.assertEqual(params["role"], "eq.student")
        self.assertEqual(params["order"], "netid.asc")
        self.assertIn("team_nickname", params["select"])
        self.assertEqual(len(json.loads(result.output)), 2)

    def test_roster_all_roles_sends_no_role_filter(self):
        _, session = self._run(
            api_client.roster, ["--role", "all"], {"users": [STUDENT, PROFESSOR]}
        )

        self.assertNotIn("role", session.params_for("users")[0])

    def test_roster_csv_has_a_header_and_empty_cells_for_nulls(self):
        result, _ = self._run(
            api_client.roster,
            ["--format", "csv"],
            {"users": [dict(STUDENT, team_nickname=None)]},
        )

        lines = result.output.strip().splitlines()
        self.assertEqual(lines[0].split(",")[:2], ["id", "netid"])
        self.assertIn(",,", lines[1], "a null team must be an empty cell")

    def test_find_user_matches_exactly_one_named_field(self):
        result, session = self._run(
            api_client.find_user, ["netid", "aaa11"], {"users": [STUDENT]}
        )

        self.assertEqual(result.exit_code, 0, result.output)
        params = session.params_for("users")[0]
        self.assertEqual(params["netid"], "eq.aaa11")
        self.assertNotIn("or", params, "exact lookup must not fan out across fields")
        self.assertNotIn("email", params)
        self.assertEqual(json.loads(result.output)["netid"], "aaa11")

    def test_find_user_lowercases_the_value_because_the_database_does(self):
        _, session = self._run(
            api_client.find_user, ["email", "  Ann@Example.Test "], {"users": [STUDENT]}
        )

        self.assertEqual(
            session.params_for("users")[0]["email"], "eq.ann@example.test"
        )

    def test_find_user_errors_when_nothing_matches(self):
        result, _ = self._run(api_client.find_user, ["netid", "zzz99"], {"users": []})

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("No user has netid 'zzz99'", result.output)

    def test_find_user_errors_when_more_than_one_matches(self):
        result, _ = self._run(
            api_client.find_user,
            ["nickname", "brave-otter"],
            {"users": [STUDENT, TEAMMATE]},
        )

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("2 users have nickname 'brave-otter'", result.output)
        self.assertIn("aaa11, bbb22", result.output)
        self.assertIn("will not guess", result.output)

    def test_find_user_refuses_a_field_that_does_not_identify_one_person(self):
        result, _ = self._run(api_client.find_user, ["name", "Ann"], {"users": []})

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("'name' is not one of", result.output)

    def test_search_users_matches_a_substring_across_five_columns(self):
        result, session = self._run(
            api_client.search_users,
            ["aard", "--role", "all"],
            {"users": [STUDENT]},
        )

        self.assertEqual(result.exit_code, 0, result.output)
        or_filter = session.params_for("users")[0]["or"]
        for column in ("name", "email", "netid", "nickname", "team_nickname"):
            self.assertIn(f'{column}.ilike."*aard*"', or_filter)
        self.assertTrue(or_filter.startswith("(") and or_filter.endswith(")"))

    def test_search_users_quotes_terms_containing_postgrest_syntax(self):
        _, session = self._run(
            api_client.search_users, ["a,b)c"], {"users": []}
        )

        self.assertIn('name.ilike."*a,b)c*"', session.params_for("users")[0]["or"])

    def test_search_users_refuses_an_empty_term(self):
        result, session = self._run(api_client.search_users, ["  "], {"users": []})

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("TERM is empty", result.output)
        self.assertEqual(session.calls, [], "must not fetch every user by accident")

    def test_export_counts_a_team_submission_once_not_once_per_member(self):
        result, _ = self._run(
            api_client.export_submissions, [], submission_payloads()
        )

        self.assertEqual(result.exit_code, 0, result.output)
        rows = json.loads(result.output)
        team_rows = [row for row in rows if row["team_nickname"] == "blue-team"]
        self.assertEqual(
            len(team_rows),
            2,
            "one row per submitted field, not per field per team member",
        )
        self.assertEqual({row["field_slug"] for row in team_rows}, {"url", "notes"})
        for row in team_rows:
            self.assertIsNone(row["netid"], "a team submission has no single owner")
            self.assertEqual(row["submitter_netid"], "bbb22")

    def test_export_omits_non_student_individual_submissions_by_default(self):
        result, _ = self._run(
            api_client.export_submissions, [], submission_payloads()
        )

        netids = {row["netid"] for row in json.loads(result.output)}
        self.assertIn("aaa11", netids)
        self.assertNotIn("ppp99", netids)

    def test_export_includes_non_students_on_request(self):
        result, _ = self._run(
            api_client.export_submissions,
            ["--include-non-students"],
            submission_payloads(),
        )

        netids = {row["netid"] for row in json.loads(result.output)}
        self.assertIn("ppp99", netids)

    def test_export_produces_no_row_for_an_assignment_nobody_submitted(self):
        payloads = submission_payloads()
        payloads["assignments"].append(
            {"slug": "unsubmitted", "is_draft": False, "closed_at": "2026-03-01T00:00:00Z"}
        )

        result, _ = self._run(api_client.export_submissions, [], payloads)

        slugs = {row["assignment_slug"] for row in json.loads(result.output)}
        self.assertNotIn(
            "unsubmitted",
            slugs,
            "the export answers what was submitted, not who is missing",
        )

    def test_export_excludes_draft_assignments_unless_asked(self):
        _, session = self._run(
            api_client.export_submissions, [], submission_payloads()
        )
        self.assertEqual(session.params_for("assignments")[0]["is_draft"], "eq.false")

        _, with_drafts = self._run(
            api_client.export_submissions, ["--include-drafts"], submission_payloads()
        )
        self.assertNotIn("is_draft", with_drafts.params_for("assignments")[0])

    def test_export_limits_to_named_assignments(self):
        result, session = self._run(
            api_client.export_submissions,
            ["--assignment", "repo"],
            {**submission_payloads(), "assignments": [
                {"slug": "repo", "is_draft": False, "closed_at": "2026-01-01T00:00:00Z"}
            ]},
        )

        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(
            session.params_for("assignments")[0]["slug"], 'in.("repo")'
        )
        self.assertEqual(
            {row["assignment_slug"] for row in json.loads(result.output)}, {"repo"}
        )

    def test_export_errors_on_an_unknown_assignment_slug(self):
        result, _ = self._run(
            api_client.export_submissions,
            ["--assignment", "nope"],
            {**submission_payloads(), "assignments": []},
        )

        self.assertNotEqual(result.exit_code, 0)
        self.assertIn("Unknown assignment slug(s): nope", result.output)
        self.assertIn("--include-drafts", result.output)

    def test_export_orders_rows_by_assignment_close_date(self):
        result, _ = self._run(
            api_client.export_submissions, [], submission_payloads()
        )

        slugs = [row["assignment_slug"] for row in json.loads(result.output)]
        self.assertEqual(slugs, ["repo", "team-project", "team-project"])

    def test_in_filter_quotes_values_so_slugs_stay_literal(self):
        self.assertEqual(
            api_client.in_filter(["a-b", "c,d"]), 'in.("a-b","c,d")'
        )


def big_roster(count):
    return [
        {
            "id": index,
            "netid": f"aaa{index:03d}",
            "name": f"Student {index}",
            "email": f"s{index}@example.test",
            "nickname": f"nick-{index}",
            "role": "student",
            "team_nickname": None,
        }
        for index in range(1, count + 1)
    ]


class PagingTest(unittest.TestCase):
    """PostgREST caps a response at `db-max-rows` and says so only in a header.

    A short grade export looks exactly like a complete one, so nothing here may
    settle for the first page.
    """

    def _config(self, session):
        return {
            "base_url": "https://example.test",
            "jwt": "faculty-token",
            "session": session,
            "timeout": 30,
            "verify_tls": True,
        }

    def _invoke(self, command, args, session):
        return CliRunner().invoke(command, args, obj=self._config(session))

    def test_get_all_rest_follows_a_full_page_with_the_remainder(self):
        session = RoutingSession({"users": big_roster(7)}, max_rows=3)

        rows = api_client.get_all_rest(
            self._config(session), "users", "id.asc", page_size=3
        )

        self.assertEqual([row["id"] for row in rows], [1, 2, 3, 4, 5, 6, 7])
        self.assertEqual(
            [headers["Range"] for headers in session.headers_for("users")],
            ["0-2", "3-5", "6-8"],
        )

    def test_get_all_rest_asks_for_an_exact_count_once_and_then_stops_asking(self):
        session = RoutingSession({"users": big_roster(7)}, max_rows=3)

        api_client.get_all_rest(self._config(session), "users", "id.asc", page_size=3)

        prefers = [headers.get("Prefer") for headers in session.headers_for("users")]
        self.assertEqual(prefers, ["count=exact", None, None])

    def test_get_all_rest_pages_on_a_deterministic_order(self):
        session = RoutingSession({"users": big_roster(7)}, max_rows=3)

        api_client.get_all_rest(self._config(session), "users", "id.asc", page_size=3)

        for params in session.params_for("users"):
            self.assertEqual(params["order"], "id.asc")

    def test_get_all_rest_needs_no_second_request_when_one_page_is_everything(self):
        session = RoutingSession({"users": big_roster(2)})

        rows = api_client.get_all_rest(self._config(session), "users", "id.asc")

        self.assertEqual(len(rows), 2)
        self.assertEqual(len(session.calls), 1)

    def test_get_all_rest_handles_an_empty_collection(self):
        session = RoutingSession({"users": []})

        rows = api_client.get_all_rest(self._config(session), "users", "id.asc")

        self.assertEqual(rows, [])
        self.assertEqual(len(session.calls), 1)

    def test_a_response_with_no_content_range_is_refused_not_accepted_short(self):
        session = NoContentRangeSession({"users": big_roster(7)}, max_rows=3)

        with self.assertRaises(click.ClickException) as caught:
            api_client.get_all_rest(
                self._config(session), "users", "id.asc", page_size=3
            )

        self.assertIn("may be incomplete", caught.exception.message)
        self.assertIn("Content-Range", caught.exception.message)

    def test_an_unknown_total_is_refused_rather_than_guessed(self):
        class StarTotal(RoutingSession):
            def request(self, method, url, **kwargs):
                response = super().request(method, url, **kwargs)
                response.headers = {"Content-Range": "0-2/*"}
                return response

        session = StarTotal({"users": big_roster(7)}, max_rows=3)

        with self.assertRaises(click.ClickException) as caught:
            api_client.get_all_rest(
                self._config(session), "users", "id.asc", page_size=3
            )

        self.assertIn("no usable row total", caught.exception.message)

    def test_a_server_that_stops_short_of_its_own_total_is_an_error(self):
        session = StallingSession({"users": big_roster(4)}, max_rows=4)

        with self.assertRaises(click.ClickException) as caught:
            api_client.get_all_rest(
                self._config(session), "users", "id.asc", page_size=4
            )

        self.assertIn("stopped returning", caught.exception.message)
        self.assertIn("incomplete", caught.exception.message)

    def test_roster_returns_every_student_past_the_row_cap(self):
        session = RoutingSession({"users": big_roster(250)}, max_rows=100)

        result = self._invoke(api_client.roster, [], session)

        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(len(json.loads(result.output)), 250)

    def test_search_users_returns_every_match_past_the_row_cap(self):
        session = RoutingSession({"users": big_roster(250)}, max_rows=100)

        result = self._invoke(api_client.search_users, ["aaa", "--role", "all"], session)

        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(len(json.loads(result.output)), 250)

    def test_export_joins_across_collections_that_each_needed_paging(self):
        # The join is the dangerous case: truncating any one collection drops
        # rows for students whose own rows arrived intact.
        students = big_roster(30)
        submissions = [
            {
                "id": student["id"],
                "assignment_slug": "repo",
                "is_team": False,
                "user_id": student["id"],
                "team_nickname": None,
                "submitter_user_id": student["id"],
            }
            for student in students
        ]
        payloads = {
            "assignments": [
                {"slug": "repo", "is_draft": False, "closed_at": "2026-01-01T00:00:00Z"}
            ],
            "assignment_submissions": submissions,
            "users": students,
            "assignment_field_submissions": [
                {
                    "assignment_submission_id": submission["id"],
                    "assignment_field_slug": "url",
                    "body": f"https://example.test/{submission['id']}",
                    "updated_at": "2026-01-01T00:00:00Z",
                }
                for submission in submissions
            ],
        }
        session = RoutingSession(payloads, max_rows=7)

        result = self._invoke(api_client.export_submissions, [], session)

        self.assertEqual(result.exit_code, 0, result.output)
        rows = json.loads(result.output)
        self.assertEqual(len(rows), 30, "every submitted field must survive the join")
        self.assertEqual(
            {row["netid"] for row in rows},
            {student["netid"] for student in students},
        )

    def test_every_collection_read_in_the_export_is_paged(self):
        session = RoutingSession(submission_payloads(), max_rows=1)

        result = self._invoke(api_client.export_submissions, [], session)

        self.assertEqual(result.exit_code, 0, result.output)
        for path in (
            "assignments",
            "assignment_submissions",
            "users",
            "assignment_field_submissions",
        ):
            self.assertGreater(
                len(session.headers_for(path)),
                1,
                f"{path} must page rather than trust one capped response",
            )
            self.assertTrue(
                all("order" in params for params in session.params_for(path)),
                f"{path} must page on a deterministic order",
            )


if __name__ == "__main__":
    unittest.main()
