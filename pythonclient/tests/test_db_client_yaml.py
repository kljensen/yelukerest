import io
import unittest

import db_client


class DbClientYamlTest(unittest.TestCase):
    def test_read_yaml_coerces_slug_and_body_values_to_strings(self):
        loaded = db_client.read_yaml(
            io.StringIO(
                """
slug: 123
body: true
points_possible: 25
is_draft: false
child:assignment_fields:
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
        self.assertEqual(loaded["child:assignment_fields"][0]["slug"], "false")
        self.assertEqual(
            loaded["child:assignment_fields"][0]["assignment_slug"],
            "123",
        )
        self.assertIs(loaded["child:assignment_fields"][0]["is_url"], True)
        self.assertEqual(loaded["child:assignment_fields"][0]["display_order"], 0)

    def test_prepare_content_accepts_implicitly_typed_body_after_read_yaml(self):
        loaded = db_client.read_yaml(
            io.StringIO(
                """
slug: false
body: 5
"""
            )
        )

        prepared = db_client.prepare_content("858", "body", loaded)

        self.assertEqual(prepared["slug"], "false")
        self.assertEqual(prepared["body"], "5")


if __name__ == "__main__":
    unittest.main()
