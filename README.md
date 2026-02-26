# lamdera-db

Write quick and *clean* scripts with Lamdera and elm-pages scripts!

Local scripting against a Lamdera backend model. Write Elm scripts that read and update your `BackendModel` directly, with type-safe codecs and Lamdera's Evergreen migrations.

## Why

- **Type-safe database** — your `BackendModel` is your schema, enforced by the Elm compiler
- **Type-safe migrations** — Lamdera's Evergreen migrations handle schema changes
- **Local scripting** — use [elm-pages](https://elm-pages.com) `BackendTask` to build scripts to query and modify your data from the command line
- **Pure Elm** — no SQL, no ORMs, no serialization boilerplate

## How it works

Your `BackendModel` (defined in `src/Types.elm`) works just like in a regular Lamdera app. The only difference is that it is persisted to disk instead of a hosted Lamdera application for use in scripts (**not** full-stack real-time Lamdera apps, just use Lamdera if you need that). It is serialized to `db.bin`, and new databases start from `Types.initialBackendModel`. Your scripts live in `script/` and can access the type-safe Lamdera database through two functions:

```elm
module LamderaDb exposing (get, update)

-- Get the current BackendModel. Loads from db.bin, checks the schema version, and Wire3-decodes it.
get : BackendTask FatalError BackendModel
-- Update the BackendModel. Loads, applies your function, Wire3-encodes, and saves.
update : (BackendModel -> BackendModel) -> BackendTask FatalError ()
```

## File Structure

```sh
lamdera-db/
├── elm.json                    # Single elm.json (Lamdera + elm-pages deps)
├── custom-backend-task.ts      # Bridge for saving db.bin
├── src/
│   ├── Types.elm               # Your BackendModel lives here
│   ├── Evergreen/
│   │   ├── V1/
│   │   │   └── Types.elm       # Snapshot of Types.elm at V1
│   │   └── Migrate/
│   │       └── V2.elm          # V1 → V2 migration
├── lib/
│   └── LamderaDb.elm           # Library code — don't edit
├── .lamdera-db/
│   ├── SchemaVersion.elm       # Current schema version number
│   ├── Migrate.elm             # Migration entry point (auto-snapshot + dispatch)
│   └── MigrateChain.elm        # Migration chain (auto-generated per snapshot)
├── script/
│   └── Example.elm             # Your scripts go here
├── test.sh                     # E2E migration test
└── db.bin                      # Your data (gitignored)
```

## Getting started

1. Fork or clone this repo
2. Install dependencies:
   ```sh
   npm install
   ```
3. Define your `BackendModel` and `initialBackendModel` in `src/Types.elm`
4. Write scripts in `script/`

## Running scripts

```bash
npx elm-pages run script/Example.elm
```

### Example script

```elm
module MyScript exposing (run)

import BackendTask
import FatalError exposing (FatalError)
import LamderaDb
import Pages.Script as Script exposing (Script)

run : Script
run =
    Script.withoutCliOptions
        (LamderaDb.update
            (\model ->
                { model
                    | todos = model.todos ++ [ { id = model.nextId, title = "Buy milk", completed = False, createdAt = 0 } ]
                    , nextId = model.nextId + 1
                }
            )
            |> BackendTask.andThen (\_ -> LamderaDb.get)
            |> BackendTask.andThen (\model -> Script.log ("Total todos: " ++ String.fromInt (List.length model.todos)))
        )
```

## Migrations

When you change your `BackendModel`, existing `db.bin` data needs to be migrated. lamdera-db includes a local Evergreen migration system that catches version mismatches and guides you through the process.

### What happens when you have pending migrations

If you change `src/Types.elm` without migrating, any script that calls `LamderaDb.get` or `LamderaDb.update` will fail with a clear error:

```
-- TYPES.ELM HAS CHANGED ---------------
BackendModel has changed since db.bin was last written, but SchemaVersion is still 1. Run: npm run migrate
```

### Full workflow for changing your schema

One command handles everything — snapshots are automatic:

```
1. Edit src/Types.elm              (change your schema)
2. Run your script                 (error: "Types changed. Run: npm run migrate")
3. npm run migrate                 (auto-snapshots, creates stub, tells you to edit it)
4. Edit src/Evergreen/Migrate/V2.elm  (implement the migration)
5. npm run migrate                 (backs up db.bin, applies migration, done)
```

#### Step 3 in detail

Running `npm run migrate` detects that your types have changed and automatically:
- Creates `src/Evergreen/V{N}/Types.elm` — frozen snapshot of your types before the change
- Creates `src/Evergreen/Migrate/V{N+1}.elm` — migration stub to implement
- Bumps `.lamdera-db/SchemaVersion.elm` to N+1
- Regenerates `.lamdera-db/Migrate.elm` with the full migration chain

The migration stub uses a compile-error sentinel — your project won't compile until you implement it. No runtime crashes, no data touched.

#### Step 5 in detail

Running `npm run migrate` again:
- Backs up `db.bin` to `db.bin.backup` (automatic, before any write)
- Applies the migration chain
- Saves the migrated data

#### Implementing the migration

Edit the generated `src/Evergreen/Migrate/V{N+1}.elm` to map old types to new:

```elm
module Evergreen.Migrate.V2 exposing (backendModel)

import Evergreen.V1.Types
import Types

backendModel : Evergreen.V1.Types.BackendModel -> Types.BackendModel
backendModel old =
    { todos =
        List.map
            (\todo ->
                { id = todo.id
                , title = todo.title
                , completed = todo.completed
                , createdAt = 0  -- new field with default
                }
            )
            old.todos
    , nextId = old.nextId
    }
```

### Testing migrations

The project includes an end-to-end migration test that replays the real user workflow:

```bash
npm test
```

This runs through a full matrix, including:
1. V1 seeding and readback
2. Schema-change rejection when `SchemaVersion` is not bumped
3. V1→V2 and V2→V3 migration correctness (with automatic backup)
4. Comment-only and non-`BackendModel` type changes being allowed
5. Natural workflow (change types, then `npm run migrate`)
6. Compile-error sentinel prevents running migration before implementing stub

## AI-First Migration Workflow (Codex Skill)

This repo includes a focused Codex skill for implementing and validating Evergreen migrations:

- Skill source: `skills/evergreen-migration-assist`
- Install locally into Codex:
  ```bash
  npm run skill:install
  ```
- Validate skill structure:
  ```bash
  npm run skill:validate
  ```

Once installed, invoke it explicitly with `$evergreen-migration-assist`.

Helpful checks from the skill:

```bash
bash skills/evergreen-migration-assist/scripts/migration_preflight.sh --apply-snapshot
bash skills/evergreen-migration-assist/scripts/migration_context.sh
bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --init
bash skills/evergreen-migration-assist/scripts/migration_example_harness.sh --run
bash skills/evergreen-migration-assist/scripts/migration_guardrails.sh
bash skills/evergreen-migration-assist/scripts/migration_guardrails.sh --full
```
