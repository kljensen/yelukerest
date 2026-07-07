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
    "deleted_count": 0
  }
]
```

The function refuses an empty list, rejects duplicate input slugs, and relies on the `meeting` table constraints for row validation. Only faculty can execute it.
If a missing meeting is still referenced by quizzes, engagements, or other rows, PostgreSQL foreign keys will reject the sync rather than silently deleting related data.

`api.platform_version.admin_api_version` is `2` or later for deployments that support this RPC.

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

## Operation Roadmap

| Operation | Status | Notes |
| --- | --- | --- |
| Meeting sync | Supported by `api.sync_meetings` | Desired-state import with delete-missing behavior. |
| Assignment sync | Supported by `api.sync_assignments` | Desired-state parent/field import with dry-run and optional delete-missing behavior. |
| Roster import | Planned | Needs a boundary between Yelukerest user rows and course-specific registration, LDAP, and nickname enrichment. |
| Quiz and assignment grade import | Planned | Should land after append-only grade history so imports record facts rather than overwrite current rows. |
| Grade exceptions | Planned | Should share the grade-history/audit design and preserve actor, reason, and source metadata. |
