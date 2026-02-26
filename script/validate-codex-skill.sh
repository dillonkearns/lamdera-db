#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="${1:-evergreen-migration-assist}"
SKILL_NAME="$SKILL_NAME" npx elm-pages run script/ValidateSkill.elm
