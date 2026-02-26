#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "Missing file: $file"
}

find_matches() {
  local pattern="$1"
  local file="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$file"
  else
    grep -En "$pattern" "$file"
  fi
}

require_file ".lamdera-db/SchemaVersion.elm"
require_file "src/Types.elm"

schema_version="$(
  awk '
    /^[[:space:]]*current[[:space:]]*=/ {
      if (match($0, /=[[:space:]]*([0-9]+)/)) {
        s = substr($0, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", s)
        print s
        exit
      }
      if (getline > 0 && match($0, /[0-9]+/)) {
        print substr($0, RSTART, RLENGTH)
        exit
      }
    }
  ' .lamdera-db/SchemaVersion.elm
)"

[[ -n "${schema_version}" ]] || fail "Could not parse SchemaVersion.current from .lamdera-db/SchemaVersion.elm"

if [[ "$schema_version" -lt 1 ]]; then
  fail "SchemaVersion.current must be >= 1, got: $schema_version"
fi

prev_version=$((schema_version - 1))
migration_file="src/Evergreen/Migrate/V${schema_version}.elm"

if [[ "$prev_version" -ge 1 ]]; then
  snapshot_file="src/Evergreen/V${prev_version}/Types.elm"
else
  snapshot_file=""
fi

echo "# Evergreen Migration Context"
echo ""
echo "SchemaVersion.current: $schema_version"
if [[ -n "$snapshot_file" ]]; then
  echo "Previous snapshot: $snapshot_file"
else
  echo "Previous snapshot: <none for V1>"
fi
echo "Current types: src/Types.elm"
echo "Target migration file: $migration_file"
echo ""

if [[ -n "$snapshot_file" && -f "$snapshot_file" ]]; then
  echo "## Types Diff (previous snapshot -> current)"
  if diff -u "$snapshot_file" src/Types.elm; then
    echo "(no diff)"
  fi
  echo ""
else
  echo "## Types Diff"
  echo "(no previous snapshot file found)"
  echo ""
fi

echo "## Migration Placeholder / Risky Marker Scan"
if [[ -f "$migration_file" ]]; then
  if find_matches "Unimplemented|Debug\\.todo|todo_implementMigration|ModelReset|ModelUnchanged|MsgUnchanged|MsgOldValueIgnored" "$migration_file"; then
    true
  else
    echo "(none found)"
  fi
else
  echo "Migration file does not exist yet."
fi
