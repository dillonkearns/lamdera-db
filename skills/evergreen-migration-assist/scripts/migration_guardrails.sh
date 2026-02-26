#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
ALLOW_RESET=0
RUN_FULL=0
TARGET_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="${2:?Missing value for --root}"
      shift 2
      ;;
    --version)
      TARGET_VERSION="${2:?Missing value for --version}"
      shift 2
      ;;
    --allow-reset)
      ALLOW_RESET=1
      shift
      ;;
    --full)
      RUN_FULL=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--root <path>] [--version <int>] [--allow-reset] [--full]" >&2
      exit 1
      ;;
  esac
done

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

has_match() {
  local pattern="$1"
  local file="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -q "$pattern" "$file"
  else
    grep -Eq "$pattern" "$file"
  fi
}

require_file ".lamdera-db/SchemaVersion.elm"
require_file "src/Types.elm"
require_file ".lamdera-db/Migrate.elm"

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

if [[ -z "$TARGET_VERSION" ]]; then
  TARGET_VERSION="$schema_version"
fi

if ! [[ "$TARGET_VERSION" =~ ^[0-9]+$ ]]; then
  fail "--version must be an integer, got: $TARGET_VERSION"
fi

if [[ "$TARGET_VERSION" -lt 1 ]]; then
  fail "--version must be >= 1, got: $TARGET_VERSION"
fi

migration_file="src/Evergreen/Migrate/V${TARGET_VERSION}.elm"
require_file "$migration_file"

if [[ "$TARGET_VERSION" -gt 1 ]]; then
  prev_snapshot="src/Evergreen/V$((TARGET_VERSION - 1))/Types.elm"
  require_file "$prev_snapshot"
fi

echo "Checking migration file: $migration_file"

if find_matches "Unimplemented|Debug\\.todo|todo_implementMigration" "$migration_file"; then
  fail "Migration still has placeholders."
fi

if find_matches "(^|[^[:alnum:]_])(ModelUnchanged|MsgUnchanged)([^[:alnum:]_]|$)" "$migration_file"; then
  fail "Migration uses ModelUnchanged/MsgUnchanged. Use explicit migration logic."
fi

if [[ "$ALLOW_RESET" -eq 0 ]]; then
  if find_matches "(^|[^[:alnum:]_])ModelReset([^[:alnum:]_]|$)" "$migration_file"; then
    fail "Migration uses ModelReset. Re-run with --allow-reset only if explicitly intended."
  fi
fi

if [[ -f ".lamdera-db/MigrateChain.elm" ]]; then
  if ! has_match "(^|[^[:alnum:]_])Evergreen\\.Migrate\\.V${TARGET_VERSION}([^[:alnum:]_]|$)" .lamdera-db/MigrateChain.elm; then
    fail ".lamdera-db/MigrateChain.elm does not reference Evergreen.Migrate.V${TARGET_VERSION}."
  fi
fi

echo "Compiling migration scripts..."
npx lamdera make .lamdera-db/Migrate.elm --output=/dev/null
if [[ -f ".lamdera-db/MigrateChain.elm" ]]; then
  npx lamdera make .lamdera-db/MigrateChain.elm --output=/dev/null
fi

if [[ -f "script/SeedDb.elm" ]]; then
  npx lamdera make script/SeedDb.elm --output=/dev/null
fi

if [[ -f "script/TestVerifyMigration.elm" ]]; then
  npx lamdera make script/TestVerifyMigration.elm --output=/dev/null
fi

if [[ "$RUN_FULL" -eq 1 ]]; then
  echo "Running full test suite..."
  npm test
fi

echo "Migration guardrails passed."
