# Yelukerest Schema Audit - 2026-07-06

## Why

The database is the core application boundary for Yelukerest. This audit looked
for states the schema permits but the course workflow does not intend: stale
online-quiz assumptions, destructive grade updates, RLS holes, admin writes that
bypass `api`, missing invariants, and migration drift.

## Research Notes

- PostgreSQL 18 documentation still recommends pinning `search_path` on
  `SECURITY DEFINER` functions and excluding untrusted writable schemas, with
  `pg_temp` searched last.
- PostgreSQL row security policies are command-specific, and delete access is
  controlled by `USING`, not `WITH CHECK`.
- PostgREST 14 continues to treat database roles, grants, RLS, views, and
  exposed RPC functions as the authorization boundary.
- Existing issue history maps several findings to open issues: #157 for FK
  indexes, #190 for modern PostgreSQL function syntax, #239 for grade history,
  #240 for paper quizzes, #242/#244 for admin API work, and #132 for `save_quiz`
  permissions.

Sources:

- https://www.postgresql.org/docs/current/ddl-rowsecurity.html
- https://www.postgresql.org/docs/current/sql-createfunction.html
- https://docs.postgrest.org/en/stable/references/auth.html
- https://docs.postgrest.org/en/stable/references/api/functions.html

## Fixed During Audit

- `api.save_quiz(int, int[])` had PostgreSQL's default public `EXECUTE`.
  Fixed by revoking public execute and granting only `student`/`ta`; covered in
  `tests/db/yeluke-quiz-answer.sql`. Closes #132.
- `data.quiz_answer` used one all-command RLS policy, so direct student
  `DELETE` was controlled only by answer ownership and not quiz writability.
  Fixed by splitting command-specific policies and testing that an expired
  student quiz answer delete affects zero rows.
- `data.quiz_submission` extension logic joined quiz exceptions only by
  `quiz_id`. Existing nested RLS mostly mitigated this, but the policy now also
  joins by `user_id` so the invariant is explicit.
- `db/src/data/yeluke/assignment_field.sql` created the updated-at trigger on
  `assignment` instead of `assignment_field`. Fixed by attaching a dedicated
  `tg_assignment_field_default` trigger to `assignment_field` with a catalog
  pgTAP assertion.

Validation:

- Full pgTAP suite against a fresh throwaway database initialized from
  `db/src`: 33 files, 325 tests, all passing.

## Open Findings

### P1: Mutable Grade Rows Are Not Auditable Facts

Current rows in `data.assignment_grade`, `data.quiz_grade`, and `data.grade`
can be updated or deleted in place. Python quiz grading also upserts with
`ON CONFLICT DO UPDATE`.

Why it matters: regrades, import mistakes, source artifacts, and grade disputes
cannot be reconstructed from database history.

Status: maps to #239. Design append-only grade events plus current-grade views.

### P1: Nullable Assignment Submission Team Flag Weakens Invariants

`data.assignment_submission.is_team` is nullable while composite foreign keys
and ownership checks depend on it. PostgreSQL allows nullable composite FK
components to skip checking, and nullable checks can evaluate to unknown.

Why it matters: direct/faculty writes can create assignment submissions with no
valid assignment/team/user shape if defaults fail or are bypassed.

Status: needs a follow-up issue. Likely fix is `is_team BOOLEAN NOT NULL`, and
probably `data.assignment.is_team BOOLEAN NOT NULL`.

### P1: SECURITY DEFINER Functions Do Not Pin search_path

The auth/settings starter-kit functions use `SECURITY DEFINER` without
function-level `SET search_path`.

Why it matters: privileged functions should not depend on the caller/session
search path. This is especially sensitive for auth and JWT helpers.

Status: needs a follow-up issue. Add `SET search_path = ... , pg_temp`, schema
qualify extension calls, and catalog tests over `pg_proc.proconfig`.

### P2: auth.sign_jwt Has Broader Grants Than Needed

`auth.sign_jwt(user_id, role)` signs caller-supplied identities and is granted
to application roles. Lack of `USAGE` on `auth` appears to block direct use
today, but the grant is a latent footgun.

Status: likely part of #228 auth/JWT hardening. Revoke direct application-role
execute and expose only constrained wrappers/views.

### P2: Team Submission History Depends on Current Team Membership

Team submissions and grades store `team_nickname`, while RLS and distributions
join through current `api.users.team_nickname`.

Why it matters: moving a student between teams can change historical access and
grade distribution membership.

Status: needs a follow-up issue. Choose either team membership history or
submission participant snapshots.

### P2: Assignment Field Submission Edits Lose History

`data.assignment_field_submission` stores one current row per field and rewrites
`submitter_user_id` to the current request user on update.

Why it matters: team work preserves only the latest body and latest editor, not
the original submitter or edit trail.

Status: should be considered with #239 append-only history. At minimum split
created-by and updated-by.

### P2: delete_quiz_question_option Misses Unused Options

`api.delete_quiz_question_option` starts from `data.quiz_answer JOIN
data.quiz_question_option`, so an option with no answers is not deleted.

Status: needs a small bugfix and pgTAP regression.

### P2: Sqitch Verify/Revert Scripts Are Placeholders

The generated `verify` and `revert` migrations contain `XXX`, so Sqitch cannot
verify grants/policies/function security or actually revert the bootstrap.

Status: needs a follow-up issue. Either implement real catalog-level verify
checks and reverts or document the bootstrap as irreversible and reproducible.

### P2: Source DDL Shape Drifts From Generated Deploy

`db/src/data/yeluke/assignment_field_submission.sql` is missing a comma before
`CONSTRAINT body_matches_pattern`. PostgreSQL accepts this as a column
constraint, while generated deploy has a table constraint.

Status: small cleanup. Existing pgTAP pattern tests cover the behavior.

### Mapped Existing Debt

- #157: create indexes for all foreign keys.
- #190: use modern PostgreSQL SQL function bodies.
- #240: remove stale online quiz question/answer workflow after moving quizzes
  fully to paper.
- #242/#244: move admin imports/upserts behind tested `api` RPCs.
