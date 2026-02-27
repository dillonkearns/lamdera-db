---
name: evergreen-migration-assist
description: Generate and harden Evergreen migration implementations for Lamdera-style projects with automatic snapshots. Use when `src/Types.elm` changed, when `src/Evergreen/Migrate/V*.elm` has placeholders to implement, when you need concrete before/after migration previews, or when you need migration safety feedback loops (guardrail checks, compile checks, and full migration test runs).
---

# Evergreen Migration Assist

Use this skill to implement one migration version at a time with explicit, safety-first feedback loops.

## Workflow

1. Run preflight to check migration state.
2. Collect migration context.
3. Propose migration mapping choices and get user confirmation ("call the shot").
4. Generate and run a concrete migration example harness.
5. Run quick guardrails.
6. Run full tests before finalizing.

### 1) Preflight (Migration State)

Run:

```bash
bash skills/evergreen-migration-assist/scripts/migration_preflight.sh --apply-snapshot
```

Interpretation:
- `STATE: READY` or `STATE: SNAPSHOT_APPLIED` → continue.
- `STATE: NEED_MIGRATE` → run `npm run migrate` first, then rerun preflight.
- `STATE: NO_DB` → snapshot need cannot be inferred from persisted data; decide whether to run `npm run migrate` based on whether `BackendModel` changed.

### 2) Collect Context

Run:

```bash
bash skills/evergreen-migration-assist/scripts/migration_context.sh
```

This prints:
- Current schema version
- Target migration module path
- Snapshot-vs-current type diff
- Placeholder/risky markers in the target migration file

### 3) Call The Shot, Then Implement

Primary edit target: the migration module (usually `src/Evergreen/Migrate/V{SchemaVersion.current}.elm`).
If guardrails surface compile errors in dependent scripts/fixtures, update those files too (for example `script/SeedDb.elm`, `script/TestVerifyMigration.elm`, or `test/fixtures/v{N}*`).

Before finalizing a migration, present the user with the exact mapping choices for newly added or changed fields and ask them to confirm.
Example: "`Todo.description` can be migrated from `title` or default to empty string. Which do you want?"

After the user chooses, implement that choice explicitly in `src/Evergreen/Migrate/V*.elm`.

Follow these rules:
- Preserve data by default.
- Map fields explicitly.
- Prefer deriving new fields from old values when possible.
- Remove `Unimplemented`, `Debug.todo`, and `todo_implementMigration` sentinels.
- Avoid `ModelReset`, `ModelUnchanged`, and `MsgUnchanged` unless explicitly intended and documented.

For detailed patterns, load:

`references/migration-best-practices.md`

### 4) Run Example Harness

Generate the per-version harness:

```bash
bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --init
```

If a stale harness exists, regenerate with:

```bash
bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --init --force
```

Then edit the generated `script/MigrationExampleV{N}.elm`:
- Replace `sampleBefore` with a concrete old-schema model value.
- Add `assertions` for key invariants you want to preserve.

Run it:

```bash
bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --run
```

Clean up the ephemeral harness when done:

```bash
bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --clean
```

When reporting back, include the exact before/after output and whether assertions passed.

### 5) Run Quick Guardrails

Run:

```bash
bash skills/evergreen-migration-assist/scripts/migration_guardrails.sh
```

This fails fast if:
- Target migration file is missing
- Placeholder tokens remain (`Unimplemented`, `Debug.todo`, `todo_implementMigration`)
- Risky defaults remain (`ModelUnchanged`/`MsgUnchanged`)
- `ModelReset` is present without explicit opt-in
- Migration scripts fail to compile (`.lamdera-db/Migrate.elm`, `script/SeedDb.elm`, `script/TestVerifyMigration.elm`)

### 6) Run Full Validation

Run:

```bash
bash skills/evergreen-migration-assist/scripts/migration_guardrails.sh --full
```

This runs the quick checks plus full project migration tests (`npm test`).

## Guardrail Policy

- Require explicit user confirmation before allowing destructive reset semantics.
- Require explicit user confirmation for ambiguous field-initialization choices before finalizing migration logic.
- Prefer deterministic migrations over implicit defaults.
- Keep migrations explicit and reviewable in source control.
- When assumptions are needed, state them in comments near the mapping logic.

## Resources

- `scripts/migration_preflight.sh`: detect current migration state and auto-run snapshot when required.
- `scripts/migration_context.sh`: build migration context quickly.
- `scripts/migration_example_harness.sh`: generate/run/clean an executable before/after migration harness.
- `scripts/migration_guardrails.sh`: compile + safety checks (+ optional full tests).
- `references/migration-best-practices.md`: migration implementation playbook.
