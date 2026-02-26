#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_NAME="${1:-evergreen-migration-assist}"
SOURCE_DIR="$REPO_ROOT/skills/$SKILL_NAME"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
TARGET_DIR="$CODEX_HOME/skills/$SKILL_NAME"

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "ERROR: Skill directory not found: $SOURCE_DIR" >&2
  exit 1
fi

mkdir -p "$CODEX_HOME/skills"

if [[ -e "$TARGET_DIR" && ! -L "$TARGET_DIR" ]]; then
  echo "ERROR: Target exists and is not a symlink: $TARGET_DIR" >&2
  echo "Remove or rename it first, then re-run." >&2
  exit 1
fi

if [[ -L "$TARGET_DIR" ]]; then
  rm "$TARGET_DIR"
fi

ln -s "$SOURCE_DIR" "$TARGET_DIR"

echo "Installed Codex skill:"
echo "  $SKILL_NAME"
echo "Symlink:"
echo "  $TARGET_DIR -> $SOURCE_DIR"
