# Admin API

Yelukerest admin tooling should prefer the `api` schema exposed by PostgREST over direct writes to `data.*`. Direct table writes couple course repos to storage details and bypass the permissions boundary that students, TAs, faculty, and app tokens use everywhere else.

## Meeting Sync

`api.meetings` already supports faculty CRUD for individual meeting rows. That was not enough for the historical course-admin workflow, which treats the YAML meeting file as the desired complete set:

1. Delete meetings missing from the YAML file.
2. Update meetings whose slugs already exist.
3. Insert meetings whose slugs are new.
4. Commit those changes as one operation and report what happened.

Use the RPC endpoint for that operation:

`POST /rest/rpc/sync_meetings`

Payload:

```json
{
  "p_meetings": [
    {
      "slug": "intro",
      "title": "Introduction",
      "summary": "Short Markdown summary",
      "description": "Long Markdown description",
      "begins_at": "2026-01-14T14:00:00Z",
      "duration": "01:20:00",
      "is_draft": false
    }
  ]
}
```

Response:

```json
[
  {
    "inserted_count": 1,
    "updated_count": 3,
    "unchanged_count": 0,
    "deleted_count": 0
  }
]
```

The function refuses an empty list, rejects duplicate input slugs, and relies on the `meeting` table constraints for row validation. Only faculty can execute it. Repeating the same payload reports matching existing rows under `unchanged_count` and does not touch their `updated_at` timestamps.
If a missing meeting is still referenced by quizzes, engagements, or other rows, PostgreSQL foreign keys will reject the sync rather than silently deleting related data.

`api.platform_version.admin_api_version` is `4` or later for deployments that support the `unchanged_count` response field.

## Assignment Sync

`api.assignments` and `api.assignment_fields` are writable by faculty, but a course assignment file is one desired-state object with child fields. Updating the parent row and field rows separately makes dry-runs, summaries, retries, and partial-failure behavior harder to reason about.

Use the RPC endpoint for assignment imports:

`POST /rest/rpc/sync_assignments`

Payload:

```json
{
  "p_delete_missing": false,
  "p_dry_run": false,
  "p_assignments": [
    {
      "slug": "version-control",
      "title": "Version Control",
      "points_possible": 25,
      "is_draft": false,
      "is_markdown": false,
      "is_team": false,
      "body": "Rendered Markdown body",
      "closed_at": "2026-03-25T23:00:00-04:00",
      "fields": [
        {
          "slug": "repo-url",
          "label": "Your Git repo URL",
          "help": "Paste the repository URL.",
          "placeholder": "https://github.com/...",
          "is_url": true,
          "is_multiline": false,
          "display_order": 0,
          "pattern": "https://.*",
          "example": "https://github.com/example/repo"
        }
      ]
    }
  ]
}
```

Response:

```json
[
  {
    "inserted_count": 1,
    "updated_count": 0,
    "unchanged_count": 0,
    "deleted_count": 0,
    "field_inserted_count": 1,
    "field_updated_count": 0,
    "field_unchanged_count": 0,
    "field_deleted_count": 0,
    "dry_run": false
  }
]
```

The function refuses an empty list, rejects duplicate assignment slugs, requires an explicit `fields` array for every assignment, and rejects duplicate field slugs within the same assignment.

When `p_delete_missing` is `false`, assignments absent from the payload are preserved. Fields are still treated as the desired field set for assignments present in the payload. When `p_delete_missing` is `true`, assignments absent from the payload are deleted after their fields are deleted. Existing submissions, grades, or field submissions can reject those deletes through PostgreSQL foreign keys, and the whole RPC rolls back.

Set `p_dry_run` to `true` to get the same summary shape without writing data.

`api.platform_version.admin_api_version` is `3` for deployments that support assignment sync.

## Assignment Grade Import

`POST /rest/rpc/import_assignment_grades`

Grades arrive as final, absolute points keyed on `assignment_slug` and `netid`:

```json
{
  "p_dry_run": false,
  "p_create_missing_submissions": true,
  "p_import_id": "exam-1-2026-03-30",
  "p_reason": "Exam 1, first sitting",
  "p_grades": [
    {
      "assignment_slug": "exam-1",
      "netid": "abc123",
      "points": 45.5,
      "description": "Missed question 7"
    }
  ]
}
```

Response:

```json
[
  {
    "inserted_count": 1,
    "updated_count": 0,
    "unchanged_count": 0,
    "submission_created_count": 1,
    "import_id": "exam-1-2026-03-30",
    "dry_run": false
  }
]
```

Curving is the client's job. The function never derives a denominator from the
payload, because a batch-relative maximum makes the same raw score mean
different things depending on which rows are in the file, and a makeup exam sat
by one student would score 100% by construction. Compute final points over the
full intended cohort before sending.

The function fails the whole import, rather than skipping rows, when it finds an
unknown `assignment_slug` or `netid`, a duplicate `assignment_slug`/`netid` pair,
a missing or null `points` value, a non-numeric `points` value, points outside
`[0, points_possible]`, or a student with no team on a team assignment. Every
message names the offending rows.

A team assignment has one submission per team, so two teammates in one payload
are two keys pointing at one row. That is rejected too: send one row per team.

`points` is required on every row; a missing score is an error rather than a
zero. `description` is optional and only written when the key is present, so an
import that carries no `description` column leaves hand-written comments alone.

Assignment grades cannot exist without an assignment submission, and a paper
exam never produces one, so `p_create_missing_submissions` defaults to `true`
and reports what it created under `submission_created_count`. Set it to `false`
to require an existing submission and fail naming the rows that lack one.

Repeating the same payload writes nothing and reports every row under
`unchanged_count`, so no redundant `corrected` rows land in
`api.assignment_grade_events`. Rows the import does write carry
`source = 'api.import_assignment_grades'` plus the `reason` and `import_id` from
the call. `import_id` is generated when the caller does not supply one and is
returned so the client can log it.

Set `p_dry_run` to `true` to get the same summary shape without writing data.

`api.platform_version.admin_api_version` is `6` or later for deployments that
support assignment grade import.

## Operation Roadmap

| Operation | Status | Notes |
| --- | --- | --- |
| Meeting sync | Supported by `api.sync_meetings` | Desired-state import with delete-missing behavior. |
| Assignment sync | Supported by `api.sync_assignments` | Desired-state parent/field import with dry-run and optional delete-missing behavior. |
| Roster import | Planned | Needs a boundary between Yelukerest user rows and course-specific registration, LDAP, and nickname enrichment. |
| Assignment grade import | Supported by `api.import_assignment_grades` | Final points keyed on `assignment_slug` + `netid`, with dry-run, an audited `import_id`, and no silently skipped rows. |
| Quiz grade import | Planned | Should follow the same contract as assignment grade import. |
| Grade exceptions | Planned | Should share the grade-history/audit design and preserve actor, reason, and source metadata. |
