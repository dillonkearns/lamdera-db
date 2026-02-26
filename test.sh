#!/bin/bash
set -euo pipefail

backup_dir=$(mktemp -d)

# --- Setup: save current repo state (using cp, not mv, so originals stay for now) ---
cp src/Types.elm "$backup_dir/"
cp script/SeedDb.elm "$backup_dir/"
cp script/Example.elm "$backup_dir/"
cp .lamdera-db/SchemaVersion.elm "$backup_dir/"
[ -f .lamdera-db/Migrate.elm ] && cp .lamdera-db/Migrate.elm "$backup_dir/"
[ -f .lamdera-db/MigrateChain.elm ] && cp .lamdera-db/MigrateChain.elm "$backup_dir/"
[ -f script/TestVerifyMigration.elm ] && cp script/TestVerifyMigration.elm "$backup_dir/"
[ -d src/Evergreen ] && cp -r src/Evergreen "$backup_dir/"

restore_v2() {
    cp "$backup_dir/Types.elm" src/Types.elm
    cp "$backup_dir/SeedDb.elm" script/SeedDb.elm
    cp "$backup_dir/Example.elm" script/Example.elm
    cp "$backup_dir/SchemaVersion.elm" .lamdera-db/SchemaVersion.elm
    [ -f "$backup_dir/Migrate.elm" ] && cp "$backup_dir/Migrate.elm" .lamdera-db/
    [ -f "$backup_dir/MigrateChain.elm" ] && cp "$backup_dir/MigrateChain.elm" .lamdera-db/
    [ -f "$backup_dir/TestVerifyMigration.elm" ] && cp "$backup_dir/TestVerifyMigration.elm" script/
    if [ -d "$backup_dir/Evergreen" ]; then
        rm -rf src/Evergreen
        cp -r "$backup_dir/Evergreen" src/Evergreen
    fi
}

cleanup() {
    restore_v2
    rm -f db.bin
    rm -f db.bin.backup
    rm -f script/TestVerifyV3.elm
    rm -f .lamdera-db/LamderaDbDeepCheckTmpTypes.elm .lamdera-db/LamderaDbDeepCheckTmpWitness.elm
    rm -rf "$backup_dir"
}
trap cleanup EXIT

# === Phase 1: V1 environment ===
cp test/fixtures/v1/Types.elm src/Types.elm
cp test/fixtures/v1/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v1/Example.elm script/Example.elm
cp test/fixtures/v1/SchemaVersion.elm .lamdera-db/SchemaVersion.elm
cp test/fixtures/v1/Migrate.elm .lamdera-db/Migrate.elm
rm -f .lamdera-db/MigrateChain.elm
# Remove V2-only files that won't compile with V1 types
rm -f script/TestVerifyMigration.elm
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
npm run migrate
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
rm -f script/TestVerifyMigration.elm
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
echo "✓ Phase 4c: Comment-only Types.elm change correctly allowed (first run)"

# Second run should hit the fast path (text equality) since fingerprint was updated
phase4c_output2=$(npx elm-pages run script/MigrationTest.elm 2>&1 || true)
if echo "$phase4c_output2" | grep -qi "BackendModel loaded"; then
    : # expected — fast path should succeed
else
    echo "✗ FAIL: Second run after comment-only change should have succeeded (fingerprint update)"
    echo "  Got: $phase4c_output2"
    exit 1
fi
echo "✓ Phase 4c: Second run hit fast path — fingerprint update verified"

# Restore V2 files
restore_v2

# === Phase 4d: Non-BackendModel type change → allowed ===
# Re-seed V2 data
rm -f db.bin
npx elm-pages run script/SeedDb.elm

# Copy V2 types with a non-BackendModel type change only
cp test/fixtures/v2-non-backend-change/Types.elm src/Types.elm

phase4d_output=$(npx elm-pages run script/MigrationTest.elm 2>&1 || true)
if echo "$phase4d_output" | grep -qi "BackendModel loaded"; then
    : # expected — non-BackendModel change should be allowed
else
    echo "✗ FAIL: Non-BackendModel Types.elm change should have been allowed"
    echo "  Got: $phase4d_output"
    exit 1
fi
echo "✓ Phase 4d: Non-BackendModel Types.elm change correctly allowed"

# Restore V2 files for clean state
restore_v2

# === Phase 5: V2→V3 migration via auto-snapshot ===
# Start with clean V2 state and V2 data
restore_v2
rm -f db.bin
npx elm-pages run script/SeedDb.elm
echo "✓ Phase 5: Seeded clean V2 data"

# Change Types.elm to V3 (triggers auto-snapshot on next npm run migrate)
cp test/fixtures/v3/Types.elm src/Types.elm
cp test/fixtures/v3/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v3/Example.elm script/Example.elm

# Run migrate — auto-snapshots V2 types, bumps to V3, generates stub
npm run migrate
echo "✓ Phase 5: Auto-snapshot V2→V3 completed"

# Install V3 migration (replaces the compile-error stub)
cp test/fixtures/v3/MigrateV3.elm src/Evergreen/Migrate/V3.elm
cp test/fixtures/v3/TestVerifyV3.elm script/TestVerifyV3.elm

# Run migration — V2→V3 (with automatic backup)
npm run migrate
echo "✓ Phase 5: V2→V3 migration completed"

# Verify backup was created
if [ -f db.bin.backup ]; then
    echo "✓ Phase 5: db.bin.backup created"
else
    echo "✗ FAIL: db.bin.backup should have been created before migration"
    exit 1
fi

# Verify V3 data
npx elm-pages run script/TestVerifyV3.elm
echo "✓ Phase 5: V3 data verified — all values correct"

# === Phase 5b: V1→V2→V3 chaining ===
# Save the V3 state that Phase 5 built
v3_backup=$(mktemp -d)
cp src/Types.elm "$v3_backup/"
cp script/SeedDb.elm "$v3_backup/"
cp script/Example.elm "$v3_backup/"
cp .lamdera-db/SchemaVersion.elm "$v3_backup/"
cp .lamdera-db/Migrate.elm "$v3_backup/"
cp .lamdera-db/MigrateChain.elm "$v3_backup/"
cp -r src/Evergreen "$v3_backup/"

# Temporarily switch to V1 env to seed V1 data
cp test/fixtures/v1/Types.elm src/Types.elm
cp test/fixtures/v1/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v1/Example.elm script/Example.elm
cp test/fixtures/v1/SchemaVersion.elm .lamdera-db/SchemaVersion.elm
cp test/fixtures/v1/Migrate.elm .lamdera-db/Migrate.elm
rm -f .lamdera-db/MigrateChain.elm
rm -rf src/Evergreen
rm -f db.bin

npx elm-pages run script/SeedDb.elm
echo "✓ Phase 5b: Re-seeded V1 data"

# Restore V3 state (keeping V1-seeded db.bin)
cp "$v3_backup/Types.elm" src/Types.elm
cp "$v3_backup/SeedDb.elm" script/SeedDb.elm
cp "$v3_backup/Example.elm" script/Example.elm
cp "$v3_backup/SchemaVersion.elm" .lamdera-db/SchemaVersion.elm
cp "$v3_backup/Migrate.elm" .lamdera-db/
cp "$v3_backup/MigrateChain.elm" .lamdera-db/
rm -rf src/Evergreen
cp -r "$v3_backup/Evergreen" src/Evergreen
rm -rf "$v3_backup"

# Run migration — should chain V1→V2→V3
npm run migrate
echo "✓ Phase 5b: V1→V2→V3 chaining migration completed"

# Verify V3 data
npx elm-pages run script/TestVerifyV3.elm
echo "✓ Phase 5b: V1→V3 chained migration verified — all values correct"

# === Phase 6: Auto-snapshot AFTER changing Types.elm (natural user workflow) ===
# This tests the realistic flow where the user:
#   1. Has V1 data in db.bin (first version, no Evergreen artifacts yet)
#   2. Changes src/Types.elm to V2 (adds a field)
#   3. Runs npm run migrate (auto-snapshots, creates stub)
#   4. Implements migration, runs npm run migrate again
# Auto-snapshot must snapshot the OLD V1 types (from db.bin), not current V2 src/Types.elm.

# Start with clean V1 state
cp test/fixtures/v1/Types.elm src/Types.elm
cp test/fixtures/v1/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v1/Example.elm script/Example.elm
cp test/fixtures/v1/SchemaVersion.elm .lamdera-db/SchemaVersion.elm
cp test/fixtures/v1/Migrate.elm .lamdera-db/Migrate.elm
rm -f .lamdera-db/MigrateChain.elm
rm -f script/TestVerifyMigration.elm script/TestVerifyV3.elm
rm -rf src/Evergreen
rm -f db.bin

npx elm-pages run script/SeedDb.elm
echo "✓ Phase 6: Seeded V1 data"

# User changes Types.elm to V2 BEFORE running migrate (natural workflow)
cp "$backup_dir/Types.elm" src/Types.elm
cp "$backup_dir/SeedDb.elm" script/SeedDb.elm
cp "$backup_dir/Example.elm" script/Example.elm
# SchemaVersion stays at 1 — user hasn't run migrate yet
# No Evergreen artifacts — this is the user's first migration

# Run migrate — should auto-snapshot OLD V1 types from db.bin, not current V2 src/Types.elm
npm run migrate
echo "✓ Phase 6: Auto-snapshot completed after Types.elm change"

# Install the real V2 migration (replace the generated stub)
cp "$backup_dir/Evergreen/Migrate/V2.elm" src/Evergreen/Migrate/V2.elm

# Run migration — should succeed if auto-snapshot captured the old V1 types correctly
phase6_output=$(npm run migrate 2>&1 || true)
if echo "$phase6_output" | grep -qi "Migrated db.bin to version"; then
    echo "✓ Phase 6: V1→V2 migration completed (natural workflow)"
else
    echo "✗ FAIL: Auto-snapshot after Types.elm change should produce working migration"
    echo "  Auto-snapshot should read old types from db.bin, not current src/Types.elm"
    echo "  Got: $phase6_output"
    exit 1
fi

# Verify migrated data reads correctly
phase6_verify=$(npx elm-pages run script/MigrationTest.elm 2>&1 || true)
if echo "$phase6_verify" | grep -qi "BackendModel loaded"; then
    echo "✓ Phase 6: Migrated data verified — natural workflow works correctly"
else
    echo "✗ FAIL: Could not read data after natural-workflow migration"
    echo "  Got: $phase6_verify"
    exit 1
fi

# === Phase 7: Double migrate with pending migration (compile-error guard) ===
# If the user runs migrate twice after types changed, the first run auto-snapshots
# and creates a stub with a compile-error sentinel. The second run should fail
# because the stub hasn't been implemented (compile error).

# Start with V1 state + data
cp test/fixtures/v1/Types.elm src/Types.elm
cp test/fixtures/v1/SeedDb.elm script/SeedDb.elm
cp test/fixtures/v1/Example.elm script/Example.elm
cp test/fixtures/v1/SchemaVersion.elm .lamdera-db/SchemaVersion.elm
cp test/fixtures/v1/Migrate.elm .lamdera-db/Migrate.elm
rm -f .lamdera-db/MigrateChain.elm
rm -f script/TestVerifyMigration.elm script/TestVerifyV3.elm
rm -rf src/Evergreen
rm -f db.bin

npx elm-pages run script/SeedDb.elm
echo "✓ Phase 7: Seeded V1 data"

# Change to V2 types and run first migrate (auto-snapshot succeeds)
cp "$backup_dir/Types.elm" src/Types.elm
cp "$backup_dir/SeedDb.elm" script/SeedDb.elm
cp "$backup_dir/Example.elm" script/Example.elm

npm run migrate
echo "✓ Phase 7: First migrate (auto-snapshot) succeeded"

# Run migrate AGAIN without implementing the stub — should fail (compile error from sentinel)
phase7_output=$(npm run migrate 2>&1 || true)
if echo "$phase7_output" | grep -qi "todo_implementMigration"; then
    echo "✓ Phase 7: Second migrate correctly blocked by compile-error sentinel"
else
    echo "✗ FAIL: Running migrate without implementing stub should produce compile error"
    echo "  Got: $phase7_output"
    exit 1
fi

rm -f db.bin
rm -f db.bin.backup
echo ""
echo "=== All migration tests passed! ==="
