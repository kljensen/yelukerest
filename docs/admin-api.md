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

## Quiz Result Import

`POST /rest/rpc/import_quiz_results`

Quizzes are paper-only and are keyed on the meeting they were sat in, so results
arrive keyed on `meeting_slug` and `netid`:

```json
{
  "p_mark_attended": true,
  "p_dry_run": false,
  "p_import_id": "quiz-3-2026-09-22",
  "p_reason": "Quiz 3",
  "p_results": [
    {
      "meeting_slug": "structuredquerylang",
      "netid": "abc123",
      "points": 11,
      "description": "Missed question 4"
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
    "attendance_inserted": 0,
    "attendance_updated": 1,
    "attendance_unchanged": 0,
    "import_id": "quiz-3-2026-09-22",
    "dry_run": false
  }
]
```

`points` is final, absolute points, exactly as for assignment grades. An OMR
sheet's `correct / total * points_possible` is computed client-side, over the
full intended cohort; the function never derives a denominator from the payload.

The function fails the whole import, rather than skipping rows, when it finds a
`meeting_slug` with no quiz, an unknown `netid`, a duplicate
`meeting_slug`/`netid` pair, a missing or null `points` value, a non-numeric
`points` value, or points outside `[0, points_possible]`. Every message names
the offending rows.

`data.quiz_grade` has a foreign key onto `data.quiz_submission`, and a paper
quiz never produces a submission through the app, so the import creates the
missing ones and reports them under `submission_created_count`. There is no flag
to turn that off: the only setting it could take is the one under which no paper
quiz grade could ever be recorded.

### `p_mark_attended`

Sitting a quiz is evidence of being in the room, so the import can record it.
This is off by default because it writes to a second table, and a side effect
that size should be visible at the call site.

When it is on, each person in the batch is reconciled against
`api.engagements` for the quiz's meeting:

| existing participation | result |
| --- | --- |
| no row at all | a row saying `attended` — counted in `attendance_inserted` |
| `absent` | promoted to `attended` — counted in `attendance_updated` |
| `attended` | left alone — counted in `attendance_unchanged` |
| `contributed`, `led` | left alone — counted in `attendance_unchanged` |

`contributed` and `led` are faculty judgements that outrank presence, and an
import must never downgrade them. Only the people and the meeting in the payload
are touched.

This replaces an `INSERT ... ON CONFLICT DO NOTHING` in the loaders that came
before, which never marked anybody attended: `ensure_student_engagement_rows()`
writes an `absent` row for every (student, meeting) pair at enrolment, so the
row always existed and the insert always did nothing.

Repeating the same payload writes nothing and reports every row under
`unchanged_count`, so no redundant `corrected` rows land in
`api.quiz_grade_events`. Rows the import does write carry
`source = 'api.import_quiz_results'` plus the `reason` and `import_id` from the
call. `import_id` is generated when the caller does not supply one and is
returned so the client can log it.

Set `p_dry_run` to `true` to get the same summary shape, including the
attendance counts, without writing data.

`api.platform_version.admin_api_version` is `7` or later for deployments that
support quiz result import.

## Deadline Extensions

Two RPCs move one deadline for one student. Both are non-destructive: they write
an exception row and touch no grade, no submission, and no grade history.

### Why these are RPCs

`faculty` already holds full CRUD on `api.assignment_grade_exceptions` and
`api.quiz_grade_exceptions`, so an extension looks like a plain POST. Each is an
RPC for its own reason:

- **Assignments.** The uniqueness rules are *partial* indexes —
  `(assignment_slug, user_id) WHERE is_team = false` and
  `(assignment_slug, team_nickname) WHERE is_team = true`. PostgREST's
  `on_conflict` carries column names but no index predicate, so it cannot name
  either arbiter, and a second grant to the same student raises a duplicate key
  error instead of moving their deadline.
- **Quizzes.** The arbiter here is a plain `UNIQUE (quiz_id, user_id)`, which
  `on_conflict` *can* express. What a POST cannot do is resolve a meeting slug
  to a quiz id and upsert on the result in one transaction.

`is_team` branching is not the reason for either: a trigger on
`data.assignment_grade_exception` already fills `is_team` from the assignment.

### `api.grant_assignment_extension`

`POST /rest/rpc/grant_assignment_extension`

```json
{
  "p_user_id": 42,
  "p_assignment_slug": "project-update-1",
  "p_closed_at": "2026-10-03T23:59:00-04:00",
  "p_fractional_credit": 0.5
}
```

Response:

```json
[
  {
    "exception_id": 17,
    "assignment_slug": "project-update-1",
    "is_team": true,
    "user_id": null,
    "team_nickname": "bright-fog",
    "closed_at": "2026-10-03T23:59:00-04:00",
    "fractional_credit": 0.5,
    "created": true
  }
]
```

`p_closed_at` is an **absolute** timestamp. The script this replaces accepted
`+7 days` and interpolated it into SQL; relative-deadline convenience belongs to
the client, which knows what "a week" means for this course.

`p_fractional_credit` defaults to `1` and is validated against the bounds read
off the table's own `CHECK` constraint, so the two cannot drift.

On a **team** assignment the student names the team: the function resolves their
*current* `team_nickname` inside the transaction, writes a team row carrying no
`user_id`, and returns the team it chose. Granting to a teammate moves the same
row rather than adding a second — `created` says which happened.

The current team is deliberately the opposite rule from
`api.import_assignment_grades`, which reaches its team through the insert-time
snapshot in `data.assignment_submission_participant`. A grade records work
already done, so it must follow the roster as it was. An extension authorises
work not yet done, and the check that consumes it
(`data.assignment_submission`'s `WITH CHECK`) joins the exception's
`team_nickname` to the submitting student's *current* team. An older team
snapshotted here would write a row nothing could ever match.

Re-granting is safe and updates both `closed_at` and `fractional_credit`. The
script this replaces omitted `fractional_credit` from its
`ON CONFLICT ... DO UPDATE`, so re-running it at reduced credit moved the
deadline and silently left the credit alone.

The function fails, naming the argument, on a missing user id, a blank
assignment slug, a missing `closed_at`, an unknown assignment slug, an unknown
user id, a `fractional_credit` outside the constraint's bounds, or a team
assignment for a student who is on no team.

### `api.grant_quiz_extension`

> **A quiz extension currently has no effect on what a student can do.** It
> records the decision and nothing else. Nothing in the database reads
> `data.quiz_grade_exception` — no view, no row-level security policy, no grade
> calculation. Confirmed against the catalog rather than by searching text: the
> only functions whose bodies mention the table are the two that *write* it
> (`api.grant_quiz_extension` and `data.upsert_quiz_grade_exception`), and no
> policy or view references it at all. Contrast
> `data.assignment_grade_exception`, which
> `data.assignment_field_submission_is_writable_by_current_user()` and
> `data.assignment_submission`'s row-level security policy both read — which is
> what makes an *assignment* extension actually let a student submit late.
>
> This is a consequence of quizzes being paper-only: there is no online quiz for
> a deadline to hold open. Granting one is a durable, auditable record that
> faculty allowed a make-up, and it is the row any future make-up window would
> be read from. It is not a mechanism that lets the student do anything today.
> Tell the student what the make-up arrangement is; the row will not tell them.

`POST /rest/rpc/grant_quiz_extension`

```json
{
  "p_user_id": 42,
  "p_meeting_slug": "structuredquerylang",
  "p_closed_at": "2026-10-03T23:59:00-04:00",
  "p_fractional_credit": 1
}
```

Response:

```json
[
  {
    "exception_id": 9,
    "meeting_slug": "structuredquerylang",
    "quiz_id": 2,
    "user_id": 42,
    "closed_at": "2026-10-03T23:59:00-04:00",
    "fractional_credit": 1,
    "created": true
  }
]
```

Quizzes are keyed on the meeting they were sat in, so a meeting that holds no
quiz is as unextendable as a meeting that does not exist, and both are named the
same way. Everything else — the absolute timestamp, the credit bounds read from
the constraint, `created`, and re-grant behaviour — matches the assignment
version.

### There is no `reset_quiz_attempt`

`add-quiz-grade-exception.sh` opened by deleting the student's `quiz_grade`,
`quiz_answer` and `quiz_submission` rows before writing the new deadline, under
a name that said nothing about it. That behaviour is not ported, and it is not
offered under an honest name either, because nothing needs it:

- Quizzes are paper-only. `data.quiz_submission`'s RLS admits `faculty` alone,
  so there is no student attempt to reset.
- A retake is a re-import through `api.import_quiz_results`, which updates the
  grade in place and leaves both the original `recorded` event and the later
  `corrected` event, with its reason and `import_id`, in
  `api.quiz_grade_events`. Deleting the submission would destroy exactly the
  history a retake should be leaving behind.
- `data.quiz_answer` has not existed since quizzes went paper-only, so the
  script raises before it writes the deadline at all.
- If a row genuinely has to go, `faculty` already hold `DELETE` on
  `api.quiz_grades` and `api.quiz_submissions`. The destructive operation is
  already available under a name that says what it does.

`api.platform_version.admin_api_version` is `8` or later for deployments that
support either extension RPC.

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
| Quiz result import | Supported by `api.import_quiz_results` | Final points keyed on `meeting_slug` + `netid`, with opt-in attendance marking, dry-run, and an audited `import_id`. |
| Deadline extensions | Supported by `api.grant_assignment_extension` / `api.grant_quiz_extension` | Absolute deadlines, current-team resolution for team assignments, non-destructive. |
| Grade exception audit trail | Planned | The exception tables carry no actor, reason, or source columns, so an extension is not yet attributable the way an imported grade is. |
