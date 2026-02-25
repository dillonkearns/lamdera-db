#!/bin/bash
set -euo pipefail

backup_dir=$(mktemp -d)

# --- Setup: save V2 files (using cp, not mv, so originals stay for now) ---
cp src/Types.elm "$backup_dir/"
cp src/Backend.elm "$backup_dir/"
cp script/SeedDb.elm "$backup_dir/"
cp script/Example.elm "$backup_dir/"
cp lib/SchemaVersion.elm "$backup_dir/"
[ -f script/Migrate.elm ] && cp script/Migrate.elm "$backup_dir/"
[ -f script/TestVerifyMigration.elm ] && cp script/TestVerifyMigration.elm "$backup_dir/"
[ -d src/Evergreen ] && cp -r src/Evergreen "$backup_dir/"

restore_v2() {
    cp "$backup_dir/Types.elm" src/Types.elm
    cp "$backup_dir/Backend.elm" src/Backend.elm
    cp "$backup_dir/SeedDb.elm" script/SeedDb.elm
    cp "$backup_dir/Example.elm" script/Example.elm
    cp "$backup_dir/SchemaVersion.elm" lib/SchemaVersion.elm
    [ -f "$backup_dir/Migrate.elm" ] && cp "$backup_dir/Migrate.elm" script/
    [ -f "$backup_dir/TestVerifyMigration.elm" ] && cp "$backup_dir/TestVerifyMigration.elm" script/
    if [ -d "$backup_dir/Evergreen" ]; then
        rm -rf src/Evergreen
        cp -r "$backup_dir/Evergreen" src/Evergreen
    fi
}

cleanup() {
    restore_v2
    rm -f db.bin
    rm -rf "$backup_dir"
}
trap cleanup EXIT

# === Phase 1: V1 environment ===
cp test/fixtures/v1/Types.elm src/Types.elm
cp test/fixtures/v1/Backend.elm src/Backend.elm
cp test/fixtures/v1/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v1/Example.elm script/Example.elm
cp test/fixtures/v1/SchemaVersion.elm lib/SchemaVersion.elm
# Remove V2-only files that won't compile with V1 types
rm -f script/Migrate.elm script/TestVerifyMigration.elm
rm -rf src/Evergreen
rm -f db.bin

# Seed V1 data using normal LamderaDb.update (same path a real user uses)
npx elm-pages run script/SeedDb.elm
echo "✓ Phase 1: Seeded V1 data"

# Verify V1 data reads back correctly
npx elm-pages run script/MigrationTest.elm
echo "✓ Phase 1: V1 data reads OK"

# === Phase 2: Switch to V2 schema (simulate user changing types) ===
# Restore V2 source files but keep db.bin (which has V1 data)
restore_v2

# Verify LamderaDb.get REJECTS V1 data (version mismatch)
if npx elm-pages run script/MigrationTest.elm 2>/dev/null; then
    echo "✗ FAIL: Should have rejected V1 data with V2 schema"
    exit 1
fi
echo "✓ Phase 2: V1 data correctly rejected by V2 schema"

# === Phase 3: Run migration ===
npx elm-pages run script/Migrate.elm
echo "✓ Phase 3: Migration completed"

# === Phase 4: Verify migrated data has correct values ===
npx elm-pages run script/TestVerifyMigration.elm
echo "✓ Phase 4: Migrated data verified — all values correct"

rm -f db.bin
echo ""
echo "=== All migration tests passed! ==="
