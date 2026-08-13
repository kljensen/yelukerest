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
assert_contains bin/new-table.sh 'new "add-$1"'
assert_contains README.md 'Create a migration with `zapadka new add-thing`'
assert_contains bin/test-rest-stack.sh 'YELUKEREST_TEST_DATABASE_URL is not the database Zapadka bootstrapped.'

for file in CLAUDE.md tests/db/README.md bin/migrate.sh bin/new-table.sh; do
  assert_not_contains "$file" sqitch
  assert_not_contains "$file" pgtap
  assert_not_contains "$file" pg_prove
done

fake_zapadka=$(mktemp)
trap 'rm -f "$fake_zapadka" "$fake_zapadka.args"' EXIT
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
