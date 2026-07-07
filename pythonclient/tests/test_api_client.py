import datetime
import io
import json
import unittest

from click.testing import CliRunner

import api_client


class FakeResponse:
    status_code = 200
    text = "ok"

    def __init__(self, payload):
        self.payload = payload

    def raise_for_status(self):
        return None

    def json(self):
        return self.payload


class FakeSession:
    def __init__(self):
        self.calls = []

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return FakeResponse(kwargs["json"])

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return FakeResponse([{"admin_api_version": 3}])


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
            "ignored": "not sent",
        }

        normalized = api_client.normalize_meeting(
            meeting,
            class_number="858",
            time_delta=datetime.timedelta(hours=1, minutes=30),
        )

        self.assertEqual(normalized["description"], "Course 858")
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
        self.assertEqual(json.loads(result.output), [{"admin_api_version": 3}])

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


if __name__ == "__main__":
    unittest.main()
