#!/bin/bash
set -euo pipefail

backup_dir=$(mktemp -d)

# --- Setup: save current repo state (using cp, not mv, so originals stay for now) ---
cp src/Types.elm "$backup_dir/"
cp src/Backend.elm "$backup_dir/"
cp script/SeedDb.elm "$backup_dir/"
cp script/Example.elm "$backup_dir/"
cp lib/SchemaVersion.elm "$backup_dir/"
[ -f script/Migrate.elm ] && cp script/Migrate.elm "$backup_dir/"
[ -f script/Snapshot.elm ] && cp script/Snapshot.elm "$backup_dir/"
[ -f script/TestVerifyMigration.elm ] && cp script/TestVerifyMigration.elm "$backup_dir/"
[ -d src/Evergreen ] && cp -r src/Evergreen "$backup_dir/"

restore_v2() {
    cp "$backup_dir/Types.elm" src/Types.elm
    cp "$backup_dir/Backend.elm" src/Backend.elm
    cp "$backup_dir/SeedDb.elm" script/SeedDb.elm
    cp "$backup_dir/Example.elm" script/Example.elm
    cp "$backup_dir/SchemaVersion.elm" lib/SchemaVersion.elm
    [ -f "$backup_dir/Migrate.elm" ] && cp "$backup_dir/Migrate.elm" script/
    [ -f "$backup_dir/Snapshot.elm" ] && cp "$backup_dir/Snapshot.elm" script/
    [ -f "$backup_dir/TestVerifyMigration.elm" ] && cp "$backup_dir/TestVerifyMigration.elm" script/
    if [ -d "$backup_dir/Evergreen" ]; then
        rm -rf src/Evergreen
        cp -r "$backup_dir/Evergreen" src/Evergreen
    fi
}

cleanup() {
    restore_v2
    rm -f db.bin
    rm -f script/TestVerifyV3.elm
    rm -f script/LamderaDbDeepCheckTmpTypes.elm script/LamderaDbDeepCheckTmpWitness.elm
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

# === Phase 1b: Modify V1 types WITHOUT bumping version (simulate user editing Types.elm) ===
# This reproduces: user adds a field to Types.elm, updates scripts to compile, but
# doesn't bump SchemaVersion. db.bin has old data. LamderaDb.get should reject it.
cp test/fixtures/v1-modified/Types.elm src/Types.elm
cp test/fixtures/v1-modified/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v1-modified/Example.elm script/Example.elm
# SchemaVersion stays at 1 — no version bump!

phase1b_output=$(npx elm-pages run script/MigrationTest.elm 2>&1 || true)
if echo "$phase1b_output" | grep -qi "BackendModel loaded"; then
    echo "✗ FAIL: Should have rejected db.bin after Types.elm changed without version bump"
    echo "  Got: $phase1b_output"
    exit 1
fi
echo "✓ Phase 1b: Schema change without version bump correctly rejected"

# Restore V1 files for clean state before Phase 2
cp test/fixtures/v1/Types.elm src/Types.elm
cp test/fixtures/v1/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v1/Example.elm script/Example.elm

# === Phase 2: Switch to V2 schema (simulate user changing types) ===
# Restore V2 source files but keep db.bin (which has V1 data)
restore_v2

# Verify LamderaDb.get REJECTS V1 data (version mismatch)
phase2_output=$(npx elm-pages run script/MigrationTest.elm 2>&1 || true)
if echo "$phase2_output" | grep -qi "schema version mismatch"; then
    : # expected
else
    echo "✗ FAIL: Expected 'Schema version mismatch' error, got:"
    echo "$phase2_output"
    exit 1
fi
echo "✓ Phase 2: V1 data correctly rejected by V2 schema"

# === Phase 3: Run migration ===
npx elm-pages run script/Migrate.elm
echo "✓ Phase 3: Migration completed"

# === Phase 4: Verify migrated data has correct values ===
npx elm-pages run script/TestVerifyMigration.elm
echo "✓ Phase 4: Migrated data verified — all values correct"

# === Phase 4b: Modify V2 types WITHOUT bumping version (same bug, V2 variant) ===
# db.bin has valid V2 data from Phase 3. Add a field to Types.elm without bumping version.
# This is exactly the scenario the user reported: V2 + added field, SchemaVersion stays 2.
cp test/fixtures/v2-modified/Types.elm src/Types.elm
cp test/fixtures/v2-modified/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v2-modified/Example.elm script/Example.elm
# SchemaVersion stays at 2 — no version bump!

# Re-seed V2 data first so db.bin definitely has V2 data
restore_v2
npx elm-pages run script/SeedDb.elm
# Now swap to v2-modified
cp test/fixtures/v2-modified/Types.elm src/Types.elm
cp test/fixtures/v2-modified/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v2-modified/Example.elm script/Example.elm
# Remove files that won't compile with v2-modified types
rm -f script/Migrate.elm script/TestVerifyMigration.elm
rm -rf src/Evergreen

phase4b_output=$(npx elm-pages run script/MigrationTest.elm 2>&1 || true)
if echo "$phase4b_output" | grep -qi "BackendModel loaded"; then
    echo "✗ FAIL: Should have rejected db.bin after V2 Types.elm changed without version bump"
    echo "  Got: $phase4b_output"
    exit 1
fi
echo "✓ Phase 4b: V2 schema change without version bump correctly rejected"

# === Phase 4c: Comment-only Types.elm change → allowed ===
# Start with clean V2 state and V2 data
restore_v2
rm -f db.bin
npx elm-pages run script/SeedDb.elm

# Copy V2 types with only a comment added
cp test/fixtures/v2-comment-only/Types.elm src/Types.elm

phase4c_output=$(npx elm-pages run script/MigrationTest.elm 2>&1 || true)
if echo "$phase4c_output" | grep -qi "BackendModel loaded"; then
    : # expected — comment-only change should be allowed
else
    echo "✗ FAIL: Comment-only Types.elm change should have been allowed"
    echo "  Got: $phase4c_output"
    exit 1
fi
echo "✓ Phase 4c: Comment-only Types.elm change correctly allowed"

# Restore V2 files
restore_v2

# === Phase 4d: Frontend-only type change → allowed ===
# Re-seed V2 data
rm -f db.bin
npx elm-pages run script/SeedDb.elm

# Copy V2 types with FrontendModel change only
cp test/fixtures/v2-frontend-change/Types.elm src/Types.elm

phase4d_output=$(npx elm-pages run script/MigrationTest.elm 2>&1 || true)
if echo "$phase4d_output" | grep -qi "BackendModel loaded"; then
    : # expected — frontend-only change should be allowed
else
    echo "✗ FAIL: Frontend-only Types.elm change should have been allowed"
    echo "  Got: $phase4d_output"
    exit 1
fi
echo "✓ Phase 4d: Frontend-only Types.elm change correctly allowed"

# Restore V2 files for clean state
restore_v2

# === Phase 5: V2→V3 migration via Snapshot.elm ===
# Start with clean V2 state and V2 data
restore_v2
rm -f db.bin
npx elm-pages run script/SeedDb.elm
echo "✓ Phase 5: Seeded clean V2 data"

# Run Snapshot.elm — snapshots V2 types, bumps to V3, generates Migrate.elm
npx elm-pages run script/Snapshot.elm
echo "✓ Phase 5: Snapshot V2→V3 completed"

# Install V3 types, backend, and migration
cp test/fixtures/v3/Types.elm src/Types.elm
cp test/fixtures/v3/Backend.elm src/Backend.elm
cp test/fixtures/v3/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v3/Example.elm script/Example.elm
cp test/fixtures/v3/MigrateV3.elm src/Evergreen/Migrate/V3.elm
cp test/fixtures/v3/TestVerifyV3.elm script/TestVerifyV3.elm

# Run migration — V2→V3
npx elm-pages run script/Migrate.elm
echo "✓ Phase 5: V2→V3 migration completed"

# Verify V3 data
npx elm-pages run script/TestVerifyV3.elm
echo "✓ Phase 5: V3 data verified — all values correct"

# === Phase 5b: V1→V2→V3 chaining ===
# Save the V3 state that Phase 5 built
v3_backup=$(mktemp -d)
cp src/Types.elm "$v3_backup/"
cp src/Backend.elm "$v3_backup/"
cp script/SeedDb.elm "$v3_backup/"
cp script/Example.elm "$v3_backup/"
cp lib/SchemaVersion.elm "$v3_backup/"
cp script/Migrate.elm "$v3_backup/"
cp -r src/Evergreen "$v3_backup/"

# Temporarily switch to V1 env to seed V1 data
cp test/fixtures/v1/Types.elm src/Types.elm
cp test/fixtures/v1/Backend.elm src/Backend.elm
cp test/fixtures/v1/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v1/Example.elm script/Example.elm
cp test/fixtures/v1/SchemaVersion.elm lib/SchemaVersion.elm
rm -f script/Migrate.elm
rm -rf src/Evergreen
rm -f db.bin

npx elm-pages run script/SeedDb.elm
echo "✓ Phase 5b: Re-seeded V1 data"

# Restore V3 state (keeping V1-seeded db.bin)
cp "$v3_backup/Types.elm" src/Types.elm
cp "$v3_backup/Backend.elm" src/Backend.elm
cp "$v3_backup/SeedDb.elm" script/SeedDb.elm
cp "$v3_backup/Example.elm" script/Example.elm
cp "$v3_backup/SchemaVersion.elm" lib/SchemaVersion.elm
cp "$v3_backup/Migrate.elm" script/
rm -rf src/Evergreen
cp -r "$v3_backup/Evergreen" src/Evergreen
rm -rf "$v3_backup"

# Run migration — should chain V1→V2→V3
npx elm-pages run script/Migrate.elm
echo "✓ Phase 5b: V1→V2→V3 chaining migration completed"

# Verify V3 data
npx elm-pages run script/TestVerifyV3.elm
echo "✓ Phase 5b: V1→V3 chained migration verified — all values correct"

rm -f db.bin
echo ""
echo "=== All migration tests passed! ==="
