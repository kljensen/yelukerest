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

## Read Operations

These are plain authenticated reads of existing `api` views, not RPCs. They add no
database objects: `faculty` already holds `select` on `api.users`,
`api.assignments`, `api.assignment_submissions`, and
`api.assignment_field_submissions`, and PostgREST already supports the filtering
each one needs. They exist in `api_client.py` so that the query lives in one place
under test instead of being pasted into a `psql -c` in every course repo.

Every one takes `--format json|csv`. CSV carries a header row and renders SQL nulls
as empty cells.

### Paging is mandatory, and it is keyset paging

PostgREST caps every response at `db-max-rows` (`PGRST_DB_MAX_ROWS`, set per
deployment in `docker-compose.base.yaml`) and reports the cap only in the
`Content-Range` header. A single GET past the cap returns HTTP 200 with a *short*
body and no error. For a grade export that is the worst available failure mode: a
truncated export is indistinguishable from a complete one, and someone grades from
it. `export-submissions` is the sharpest case, because it reads four collections and
joins them, so truncation in any one drops rows for students whose own rows arrived
intact.

Paging by `offset` does not fix it. A unique `order` makes the *ordering*
deterministic, but an offset names a position, and positions move. If a student
submits between two requests and the new row sorts into a page already fetched,
everything after it shifts down one: the next offset re-reads a row already held and
steps over one never seen. These commands run against a live course, and the
notorious moment to run an export is the minutes around a deadline — exactly when
rows are arriving.

Every collection read therefore goes through `get_all_rest`, which pages by **key**,
not by position:

- each page after the first is fetched by naming the last row seen, so the request
  is `?id=gt.<last>` rather than `?offset=<n>`. Rows arriving or vanishing on either
  side of the cursor cannot shift it. An insert behind the cursor is simply missed —
  it was not there when that part of the collection was read — and an insert ahead
  of it is picked up; nothing is skipped or duplicated either way.
- `key` is a set of NOT NULL columns unique together, and it fixes both the sort
  order and the cursor: `users` on `netid` or `id`, `assignments` on `slug`,
  `assignment_submissions` on `id`, and `assignment_field_submissions` on its full
  composite primary key. PostgREST has no row-value `(a, b) > (x, y)` syntax, so the
  composite comparison is spelled out:

  ```
  and=(or(assignment_submission_id.gt."4",
          and(assignment_submission_id.eq."4",assignment_field_slug.gt."repo-url")))
  ```

  It goes in `and=` rather than `or=` so it cannot collide with a command's own
  filters, which are separate top-level parameters and are ANDed with it.
- the walk ends on an **empty** page, never on a short one. `db-max-rows` makes every
  page short, so treating shortness as the end reintroduces the truncation this
  exists to prevent. That costs one extra request per read, which is the correct
  price.
- `assignments` pages on `slug` and is sorted into `closed_at` order afterwards.
  `closed_at` is nullable and repeats, which makes a poor cursor, and a course's
  worth of assignments sorts for free.

#### The row count is a cross-check, not a gate

The first request of each read sends `Prefer: count=exact`, so `Content-Range`
carries a real total (`0-999/4500`) rather than `0-999/*`. That total is compared
against the rows actually collected, and **a mismatch prints a warning to stderr and
nothing else**. Neither alternative is defensible: failing would make exports
unusable in the minutes around a deadline, and staying silent would hide a real
"the collection moved under you" signal from someone about to grade from the output.
Under keyset paging a moved count means the collection changed during the walk, not
that the walk lost anything. A missing or `*` total is likewise a warning — the read
is still complete, only the cross-check is gone.

`api.platform_version` is the one read left unpaged: it is a single-row metadata
view, and it must answer under `AUTH_NONE` before credentials are established.

### `roster`

`GET /rest/users?role=eq.student&order=netid.asc`

Students by default; `--role ta|faculty|observer|all` selects another set. This is
the "who is in this course" read that quiz grading and CSV report scripts need.

### `find-user FIELD VALUE`

`GET /rest/users?<field>=eq.<value>`

`FIELD` is `netid`, `email`, or `nickname`, and the caller must say which. It is
deliberately not a polymorphic resolver. The clause it replaces matched
`email = X OR netid = X OR nickname = X` at once, so a value that happened to
resemble another person's netid resolved to the wrong person without saying so.

The command errors on zero matches and, separately, on more than one. All three
lookup columns are `UNIQUE NOT NULL` on `data.user`, so a second match cannot
happen through the schema; the check is an invariant assertion, and if it ever
fires it means the filter, not the data, is wrong. The value is lowercased first,
because `clean_user_fields()` lowercases all three columns on write.

`name` and `team_nickname` are not offered here. They do not identify one person,
which is what `search-users` is for.

### `search-users TERM`

`GET /rest/users?or=(name.ilike."*TERM*",…)`

Substring search over `name`, `email`, `netid`, `nickname`, and `team_nickname`.
Kept as a separate command from `find-user` so that "show me candidates" and
"resolve this person" cannot drift back into one operation. `--role` narrows it the
same way as `roster`. An empty term is refused rather than silently listing
everyone.

### `export-submissions`

One row per **submitted field**, joining `api.assignments`,
`api.assignment_submissions`, `api.assignment_field_submissions`, and `api.users`.

Columns: `assignment_slug`, `is_team`, `submission_id`, `team_nickname`, `netid`,
`name`, `email`, `nickname`, `submitter_netid`, `field_slug`, `body`,
`submitted_at`. Rows are ordered by the assignment's `closed_at`, then by team or
student, then by submission and field.

The export is submission-centric, which is a deliberate departure from the
`dump-submissions.sql` query it replaces:

- **A team submission appears once**, carrying its `team_nickname` and the netid of
  whoever submitted it. The old query repeated it once per current team member.
  Attributing a team submission to people requires the roster *as it stood when the
  work was submitted*; the database keeps exactly that in
  `data.assignment_submission_participant`, precisely because "later team roster
  changes must not rewrite historical submitted work". That table is not in the
  `api` schema and so is not reachable over PostgREST, and the only membership this
  API can see — each user's current `team_nickname` — is wrong for anyone who
  changed teams after submitting. Emitting one row per submission is the honest
  shape for the data available.
- **An assignment nobody submitted produces no rows.** The old query cross-joined
  every user with every assignment, so a blank body meant "no submission", "a
  submission missing this field", or "an empty answer", indistinguishably. Who has
  *not* submitted is a different question; answer it by subtracting this export
  from `roster`.
- **Draft assignments are excluded** unless `--include-drafts`. A draft assignment
  is not yet real work.
- **Individual submissions owned by non-students are excluded** unless
  `--include-non-students`, so faculty test submissions stay out of a grading
  export. Team submissions are always included; a team has no single owner to
  filter on.

`--assignment SLUG` is repeatable and limits the export. A slug that matches
nothing is an error naming it, rather than a silently empty export.

## Operation Roadmap

| Operation | Status | Notes |
| --- | --- | --- |
| Meeting sync | Supported by `api.sync_meetings` | Desired-state import with delete-missing behavior. |
| Assignment sync | Supported by `api.sync_assignments` | Desired-state parent/field import with dry-run and optional delete-missing behavior. |
| Roster read | Supported by `api_client.py roster` | `GET api.users` filtered by role. No new database objects. |
| User lookup | Supported by `api_client.py find-user` / `search-users` | Exact resolution on one named field, kept separate from substring search. |
| Submission export | Supported by `api_client.py export-submissions` | One row per submitted field; a team submission appears once. |
| Roster import | Planned | Needs a boundary between Yelukerest user rows and course-specific registration, LDAP, and nickname enrichment. |
| Assignment grade import | Supported by `api.import_assignment_grades` | Final points keyed on `assignment_slug` + `netid`, with dry-run, an audited `import_id`, and no silently skipped rows. |
| Quiz grade import | Planned | Should follow the same contract as assignment grade import. |
| Grade exceptions | Planned | Should share the grade-history/audit design and preserve actor, reason, and source metadata. |
