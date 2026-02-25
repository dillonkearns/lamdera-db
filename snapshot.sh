#!/bin/bash
set -euo pipefail

# Read current version from lib/SchemaVersion.elm
current=$(sed -n 's/.*current = \([0-9]*\).*/\1/p' lib/SchemaVersion.elm)
next=$((current + 1))

echo "Current schema version: $current"
echo "Creating snapshot V${current} and migration stub V${next}..."

# Create Evergreen/V{current}/Types.elm
mkdir -p "src/Evergreen/V${current}"
sed "s/^module Types/module Evergreen.V${current}.Types/" src/Types.elm > "src/Evergreen/V${current}/Types.elm"

# Create migration stub
mkdir -p "src/Evergreen/Migrate"
cat > "src/Evergreen/Migrate/V${next}.elm" << EOF
module Evergreen.Migrate.V${next} exposing (backendModel)

import Evergreen.V${current}.Types
import Types


backendModel : Evergreen.V${current}.Types.BackendModel -> Types.BackendModel
backendModel old =
    -- TODO: implement migration
    Debug.todo "Implement V${current} -> V${next} migration"
EOF

# Bump SchemaVersion
sed -i '' "s/current = ${current}/current = ${next}/" lib/SchemaVersion.elm

echo ""
echo "Created:"
echo "  src/Evergreen/V${current}/Types.elm  (snapshot of current types)"
echo "  src/Evergreen/Migrate/V${next}.elm   (migration stub - implement this!)"
echo "  lib/SchemaVersion.elm                 (bumped to ${next})"
echo ""
echo "Next steps:"
echo "  1. Modify src/Types.elm with your schema changes"
echo "  2. Implement the migration in src/Evergreen/Migrate/V${next}.elm"
echo "  3. Update script/Migrate.elm to handle version ${current} -> ${next}"
echo "  4. Run: npm test"
