#!/usr/bin/env sh
set -eu

assert_contains() {
  file=$1
  pattern=$2
  if ! grep -Fq -- "$pattern" "$file"; then
    echo "expected $file to contain: $pattern" >&2
    exit 1
  fi
}

assert_not_contains() {
  file=$1
  pattern=$2
  if grep -Fiq -- "$pattern" "$file"; then
    echo "unexpected legacy reference in $file: $pattern" >&2
    exit 1
  fi
}

assert_contains bin/migrate.sh 'deploy --target "$target"'
assert_contains bin/test-db.sh 'test --target test'
assert_contains bin/test-db.sh 'YELUKEREST_RESET_DATABASE_URL="$YELUKEREST_TEST_DATABASE_URL"'
assert_contains bin/bootstrap-db.sh './authapp/sql/create-authapp-db-role.sh'
assert_contains bin/new-table.sh 'new "add-$1"'
assert_contains README.md 'Create a migration with `zapadka new add-thing`'
assert_contains bin/test-rest-stack.sh 'do not identify the same database.'

for file in CLAUDE.md tests/db/README.md bin/migrate.sh bin/new-table.sh; do
  assert_not_contains "$file" sqitch
  assert_not_contains "$file" pgtap
  assert_not_contains "$file" pg_prove
done

legacy_paths=$(git ls-files | grep -Ei '(^db/migrations/|sqitch|pgtap|pg_prove)' || true)
if [ -n "$legacy_paths" ]; then
  echo "unexpected legacy files:" >&2
  echo "$legacy_paths" >&2
  exit 1
fi

legacy_references=$(git grep -inE 'sqitch|pg_tap|pgtap|pg_prove' -- \
  ':!tests/scripts/zapadka-workflow.sh' || true)
if [ -n "$legacy_references" ]; then
  echo "unexpected legacy references:" >&2
  echo "$legacy_references" >&2
  exit 1
fi

fake_zapadka=$(mktemp)
report=$(mktemp)
project=
probe_dir=
probe_id=
probe_deployed=

# The throwaway migration below is deployed to the test target; put the file
# back and revert it however this script ends, so the target is left as it was.
# A revert that fails is itself a failure: the target would hold an applied
# migration that exists in no checkout, which breaks every later status,
# rehash, and test-db.sh run. The temporary project is kept on that path so the
# revert can be retried by hand from it.
cleanup() {
  rm -f "$fake_zapadka" "$fake_zapadka.args"
  if [ -n "$probe_deployed" ]; then
    cp "$probe_dir/deploy.sql.orig" "$probe_dir/deploy.sql"
    if ! "$ZAPADKA_BIN" -C "$project" -q revert --target test "$probe_id" >"$report" 2>&1; then
      cat "$report" >&2
      echo "could not revert probe migration $probe_id from the test target;" >&2
      echo "the target now holds a migration no checkout has. Retry with:" >&2
      echo "  $ZAPADKA_BIN -C $project revert --target test $probe_id" >&2
      rm -f "$report"
      exit 1
    fi
  fi
  rm -f "$report"
  if [ -n "$project" ]; then
    rm -rf "$project"
  fi
}
trap cleanup EXIT
cat >"$fake_zapadka" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$@" >"$0.args"
EOF
chmod +x "$fake_zapadka"

ENV_FILE=/dev/null ZAPADKA_BIN="$fake_zapadka" ./bin/migrate.sh
expected=$(printf 'deploy\n--target\ndevelopment')
actual=$(cat "$fake_zapadka.args")
if [ "$actual" != "$expected" ]; then
  echo "unexpected Zapadka arguments: $actual" >&2
  exit 1
fi

ZAPADKA_BIN="$fake_zapadka" ./bin/new-table.sh widgets
expected=$(printf 'new\nadd-widgets')
actual=$(cat "$fake_zapadka.args")
if [ "$actual" != "$expected" ]; then
  echo "unexpected new-table Zapadka arguments: $actual" >&2
  exit 1
fi

# What a deployed migration may and may not change.
#
# Zapadka 0.6 records a deployed migration's identity as its parse tree
# (structural-v1), not its bytes (raw-v1). The property that buys, and the one
# a future upgrade must not quietly lose: a cosmetic edit to a deployed
# deploy.sql is accepted, a substantive edit is still refused with
# history.definition_changed, and no flag resets it. A test of the happy path
# alone would pass on a build that had regressed to byte hashing, so every
# refusal is asserted too.
#
# The cases run against the disposable test target, with a throwaway migration
# in a temporary copy of the project so no checked-in migration is edited. The
# target's registry is converted first (verified rehash, a no-op once done),
# because the property only holds for structural-v1 migrations.

if [ -f "${ENV_FILE:-.env}" ]; then
  set -a
  . "${ENV_FILE:-.env}"
  set +a
fi

ZAPADKA_BIN="${ZAPADKA_BIN:-zapadka}"

if ! command -v "$ZAPADKA_BIN" >/dev/null 2>&1; then
  echo "$ZAPADKA_BIN is required to run the migration history cases." >&2
  exit 127
fi

: "${YELUKEREST_TEST_DATABASE_URL:?YELUKEREST_TEST_DATABASE_URL is required and must use a privileged disposable-test role}"

# zapadka.toml resolves the test target from that variable alone, and what
# follows deploys SQL and rewrites the registry it finds there. The variable's
# name is not proof of anything: a pre-exported value or another ENV_FILE can
# put any database behind it. The disposable database is zapcheck; refuse
# every other name.
test_database=${YELUKEREST_TEST_DATABASE_URL##*/}
test_database=${test_database%%\?*}
if [ "$test_database" != zapcheck ]; then
  echo "refusing to run migration history cases against database '$test_database':" >&2
  echo "YELUKEREST_TEST_DATABASE_URL must name the disposable database zapcheck" >&2
  exit 1
fi

zap() {
  "$ZAPADKA_BIN" -C "$project" -q "$@"
}

# status must accept the checked-out probe as applied and unchanged.
expect_probe_intact() {
  case=$1
  if ! zap status --target test --output json >"$report" 2>&1; then
    echo "$case: status refused the probe migration:" >&2
    cat "$report" >&2
    exit 1
  fi
  if ! grep -A2 -F '"slug": "prove-structural-hashing"' "$report" |
    grep -Fq '"status": "applied"'; then
    echo "$case: status did not report the probe migration applied" >&2
    exit 1
  fi
}

# status must refuse the checked-out probe as a history error.
expect_probe_changed() {
  case=$1
  if zap status --target test --output json >"$report" 2>&1; then
    echo "$case: status accepted a substantive edit to a deployed migration" >&2
    exit 1
  fi
  if ! grep -Fq history.definition_changed "$report"; then
    echo "$case: status failed for another reason:" >&2
    cat "$report" >&2
    exit 1
  fi
}

project=$(mktemp -d)
cp zapadka.toml "$project/"
cp -R migrations "$project/migrations"

# deploy applies everything pending, and cleanup reverts only the probe. The
# target must already be at the checkout, so the probe is all deploy can apply
# and the target really does end with the migrations it started with.
if ! zap status --target test --output json >"$report" 2>&1; then
  echo "the test target's history must be intact before the probe is deployed:" >&2
  cat "$report" >&2
  exit 1
fi
if grep -Fq '"status": "pending"' "$report"; then
  echo "the test target is behind the checkout; run 'zapadka deploy --target test' before these cases" >&2
  exit 1
fi

zap new prove-structural-hashing >/dev/null
probe_dir=$(ls -d "$project"/migrations/*-prove-structural-hashing)
probe_id=$(sed -n 's/^id = "\(.*\)"$/\1/p' "$probe_dir/migration.toml")

# The function body is dollar-quoted: everything inside it, comments included,
# is the stored function and therefore substantive.
cat >"$probe_dir/deploy.sql" <<'EOF'
-- Throwaway migration: tests/scripts/zapadka-workflow.sh deploys, edits, and
-- reverts it to prove what a deployed migration may and may not change.
CREATE FUNCTION data.structural_hashing_probe() RETURNS text
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Inside a dollar-quoted body a comment is part of the stored function.
    RETURN 'probe';
END;
$function$;
EOF
cat >"$probe_dir/verify.sql" <<'EOF'
DO $$
BEGIN
    IF data.structural_hashing_probe() <> 'probe' THEN
        RAISE EXCEPTION 'structural_hashing_probe() returned %', data.structural_hashing_probe();
    END IF;
END $$;
EOF
cat >"$probe_dir/revert.sql" <<'EOF'
DROP FUNCTION data.structural_hashing_probe();
EOF
cp "$probe_dir/deploy.sql" "$probe_dir/deploy.sql.orig"

if ! zap lint >"$report" 2>&1; then
  echo "the probe migration does not lint:" >&2
  cat "$report" >&2
  exit 1
fi

if ! zap deploy --target test >"$report" 2>&1; then
  echo "deploying the probe migration to the test target failed:" >&2
  cat "$report" >&2
  exit 1
fi
probe_deployed=1

if ! zap rehash --target test >"$report" 2>&1; then
  echo "converting the test target to structural hashing failed:" >&2
  cat "$report" >&2
  exit 1
fi

expect_probe_intact 'probe as deployed'
if ! grep -A6 -F '"slug": "prove-structural-hashing"' "$report" |
  grep -Fq '"definition_algorithm": "structural-v1"'; then
  echo "the probe migration was not recorded under structural-v1" >&2
  exit 1
fi

# Case 1: a comment and whitespace change outside any body is cosmetic. Under
# raw-v1 this was refused, which is what made deleting registry rows the path
# of least resistance. The body is byte-identical to the original.
cat >"$probe_dir/deploy.sql" <<'EOF'
-- Throwaway migration, with its leading comment rewritten after deploy.


CREATE FUNCTION data.structural_hashing_probe()
	RETURNS text
	LANGUAGE plpgsql
	AS $function$
BEGIN
    -- Inside a dollar-quoted body a comment is part of the stored function.
    RETURN 'probe';
END;
$function$;
EOF
expect_probe_intact 'case 1 (comment and whitespace edit)'
if ! zap verify --target test "$probe_id" >"$report" 2>&1; then
  echo "case 1: verify refused a comment and whitespace edit:" >&2
  cat "$report" >&2
  exit 1
fi

# Case 2: a string literal is substantive; the deployed function would return
# something else.
sed "s/RETURN 'probe';/RETURN 'probe, edited';/" "$probe_dir/deploy.sql.orig" \
  >"$probe_dir/deploy.sql"
expect_probe_changed 'case 2 (string literal edit)'

# Case 3: a comment inside the dollar-quoted body is substantive too. Comments
# are ignored only in the SQL Zapadka parses; the body is a string PostgreSQL
# stores verbatim, so this is the case people get wrong.
sed 's/-- Inside a dollar-quoted body a comment is part of the stored function./-- Edited inside the body./' \
  "$probe_dir/deploy.sql.orig" >"$probe_dir/deploy.sql"
grep -Fq 'Edited inside the body' "$probe_dir/deploy.sql"
expect_probe_changed 'case 3 (comment edit inside a dollar-quoted body)'

# Case 4: --accept-current adopts changed legacy (raw-v1) SQL; it cannot reset
# a structural-v1 migration after a substantive edit. The remedy is a
# corrective migration, never the registry.
if zap rehash --target test --accept-current \
  --reason 'tests/scripts/zapadka-workflow.sh: must be refused' >"$report" 2>&1; then
  echo "case 4: rehash --accept-current accepted a substantive edit to a structural migration" >&2
  exit 1
fi
if ! grep -Fq history.definition_changed "$report"; then
  echo "case 4: rehash --accept-current failed for another reason:" >&2
  cat "$report" >&2
  exit 1
fi
expect_probe_changed 'case 4 (after rehash --accept-current)'

# The original file must still be accepted, so the refusals above were about
# the edits and not about the target.
cp "$probe_dir/deploy.sql.orig" "$probe_dir/deploy.sql"
expect_probe_intact 'probe restored'
