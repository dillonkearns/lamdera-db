#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
APPLY_SNAPSHOT=0

usage() {
  cat <<'EOF'
Usage: migration_preflight.sh [options]

Options:
  --root <path>       Project root (default: current directory)
  --apply-snapshot    If snapshot is required, run npm run migrate automatically
  --help              Show this help text

Exit codes:
  0  Ready (or snapshot auto-applied)
  2  Snapshot required (not auto-applied)
  3  Pending migration exists (run npm run migrate first)
  1  Unexpected failure
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "Missing file: $file"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="${2:?Missing value for --root}"
      shift 2
      ;;
    --apply-snapshot)
      APPLY_SNAPSHOT=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

cd "$ROOT"

require_file "script/MigrationTest.elm"
require_file ".lamdera-db/Migrate.elm"

if [[ ! -f "db.bin" ]]; then
  echo "STATE: NO_DB"
  echo "No db.bin found. Snapshot need cannot be inferred from persisted data."
  echo "If you changed BackendModel and want to start a new migration step, run: npm run migrate"
  exit 0
fi

echo "Running migration preflight..."
set +e
output="$(npx elm-pages run script/MigrationTest.elm 2>&1)"
status=$?
set -e

if [[ "$status" -eq 0 ]]; then
  echo "STATE: READY"
  echo "No pending snapshot/migration detected."
  exit 0
fi

echo "$output"

if printf '%s' "$output" | grep -qi "Schema version mismatch"; then
  echo "STATE: NEED_MIGRATE"
  echo "Run: npm run migrate"
  exit 3
fi

if printf '%s' "$output" | grep -qi "Types.elm has changed"; then
  if [[ "$APPLY_SNAPSHOT" -eq 1 ]]; then
    echo "STATE: NEED_SNAPSHOT"
    echo "Applying snapshot via npm run migrate..."
    npm run migrate
    echo "STATE: SNAPSHOT_APPLIED"
    exit 0
  fi

  echo "STATE: NEED_SNAPSHOT"
  echo "Run: npm run migrate"
  exit 2
fi

echo "STATE: UNKNOWN_ERROR"
echo "Could not classify migration state from MigrationTest output."
exit 1
