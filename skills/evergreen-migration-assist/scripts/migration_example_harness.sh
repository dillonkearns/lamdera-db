#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
DO_INIT=0
DO_RUN=0
DO_CLEAN=0
FORCE=0
TARGET_VERSION=""

usage() {
  cat <<'EOF'
Usage: migration_example_harness.sh [options]

Options:
  --root <path>     Project root (default: current directory)
  --version <int>   Target migration version (default: SchemaVersion.current)
  --init            Generate example harness file (default action)
  --run             Run example harness with elm-pages
  --clean           Delete generated harness file
  --force           Overwrite harness file when used with --init
  --help            Show this help text

Examples:
  bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --init
  bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --init --force
  bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --run
  bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --clean
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

find_matches() {
  local pattern="$1"
  local file="$2"
  if command -v rg >/dev/null 2>&1; then
    rg -n "$pattern" "$file"
  else
    grep -En "$pattern" "$file"
  fi
}

parse_schema_version() {
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
}

render_template() {
  local script_file="$1"
  local module_name="$2"
  local old_module="$3"
  local migrate_module="$4"
  local old_version="$5"
  local new_version="$6"

  cat >"$script_file" <<EOF
module ${module_name} exposing (run)

import BackendTask exposing (BackendTask)
import Debug
import ${migrate_module} as Migrate
import ${old_module} as Old
import FatalError exposing (FatalError)
import Pages.Script as Script exposing (Script)
import Types


type alias Assertion =
    { name : String
    , ok : Bool
    , details : String
    }


run : Script
run =
    Script.withoutCliOptions
        (let
            before =
                sampleBefore

            after =
                Migrate.backendModel before

            results =
                assertions before after

            failed =
                List.filter (\assertion -> not assertion.ok) results

            summary =
                "ASSERTION_SUMMARY: passed="
                    ++ String.fromInt (List.length results - List.length failed)
                    ++ " failed="
                    ++ String.fromInt (List.length failed)
                    ++ " total="
                    ++ String.fromInt (List.length results)
         in
         Script.log ("Before (V${old_version}):\\n" ++ Debug.toString before)
            |> BackendTask.andThen (\_ -> Script.log ("After  (V${new_version}):\\n" ++ Debug.toString after))
            |> BackendTask.andThen (\_ -> Script.log summary)
            |> BackendTask.andThen
                (\_ ->
                    if List.isEmpty results then
                        Script.log "No custom assertions defined yet. Add checks in assertions."

                    else if List.isEmpty failed then
                        Script.log "Example assertions passed."

                    else
                        BackendTask.fail
                            (FatalError.build
                                { title = "Example assertions failed"
                                , body =
                                    summary
                                        ++ "\\n"
                                        ++ String.join "\\n" (List.map formatFailure failed)
                                }
                            )
                )
        )


sampleBefore : Old.BackendModel
sampleBefore =
    Debug.todo "TODO_SAMPLE_BEFORE_MODEL"


assertions : Old.BackendModel -> Types.BackendModel -> List Assertion
assertions before after =
    -- Add explicit safety checks for important invariants.
    -- Example checks to consider:
    --   * list lengths preserved
    --   * IDs unchanged
    --   * newly added fields have expected derived/default values
    let
        _ =
            ( before, after )
    in
    []


formatFailure : Assertion -> String
formatFailure assertion =
    "- " ++ assertion.name ++ ": " ++ assertion.details
EOF
}

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
    --init)
      DO_INIT=1
      shift
      ;;
    --run)
      DO_RUN=1
      shift
      ;;
    --clean)
      DO_CLEAN=1
      shift
      ;;
    --force)
      FORCE=1
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

if [[ "$DO_INIT" -eq 0 && "$DO_RUN" -eq 0 && "$DO_CLEAN" -eq 0 ]]; then
  DO_INIT=1
fi

cd "$ROOT"

require_file ".lamdera-db/SchemaVersion.elm"
require_file "src/Types.elm"

schema_version="$(parse_schema_version)"
[[ -n "$schema_version" ]] || fail "Could not parse SchemaVersion.current from .lamdera-db/SchemaVersion.elm"

if [[ -z "$TARGET_VERSION" ]]; then
  TARGET_VERSION="$schema_version"
fi

if ! [[ "$TARGET_VERSION" =~ ^[0-9]+$ ]]; then
  fail "--version must be an integer, got: $TARGET_VERSION"
fi

if [[ "$TARGET_VERSION" -lt 2 ]]; then
  fail "Migration example harness requires version >= 2 (no previous snapshot for V1)."
fi

OLD_VERSION=$((TARGET_VERSION - 1))
old_snapshot_file="src/Evergreen/V${OLD_VERSION}/Types.elm"
migration_file="src/Evergreen/Migrate/V${TARGET_VERSION}.elm"
module_name="MigrationExampleV${TARGET_VERSION}"
script_file="script/${module_name}.elm"
old_module="Evergreen.V${OLD_VERSION}.Types"
migrate_module="Evergreen.Migrate.V${TARGET_VERSION}"

require_file "$old_snapshot_file"
require_file "$migration_file"

if [[ "$DO_INIT" -eq 1 ]]; then
  if [[ -f "$script_file" && "$FORCE" -ne 1 ]]; then
    echo "Harness already exists: $script_file"
    if find_matches "TODO_SAMPLE_BEFORE_MODEL|Debug\\.todo" "$script_file"; then
      fail "Existing harness still has placeholders. Use --force to regenerate or edit the current file before --run."
    fi
    echo "Use --force to overwrite."
  else
    render_template "$script_file" "$module_name" "$old_module" "$migrate_module" "$OLD_VERSION" "$TARGET_VERSION"
    echo "Generated harness: $script_file"
    echo "Next: replace TODO_SAMPLE_BEFORE_MODEL with a concrete ${old_module}.BackendModel value."
  fi
fi

if [[ "$DO_RUN" -eq 1 ]]; then
  require_file "$script_file"

  if find_matches "TODO_SAMPLE_BEFORE_MODEL|Debug\\.todo" "$script_file"; then
    fail "Harness still has placeholders. Fill sampleBefore before running."
  fi

  echo "Running migration example harness: $script_file"
  npx elm-pages run "$script_file"
fi

if [[ "$DO_CLEAN" -eq 1 ]]; then
  if [[ -f "$script_file" ]]; then
    rm "$script_file"
    echo "Removed harness: $script_file"
  else
    echo "No harness file to remove: $script_file"
  fi
fi
