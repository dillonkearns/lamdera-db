# lamdera-db

Write quick and *clean* scripts with Lamdera and elm-pages scripts!

Local scripting against a Lamdera backend model. Write Elm scripts that read and update your `BackendModel` directly, with type-safe codecs and Lamdera's Evergreen migrations.

## Why

- **Type-safe database** — your `BackendModel` is your schema, enforced by the Elm compiler
- **Type-safe migrations** — Lamdera's Evergreen migrations handle schema changes
- **Local scripting** — use [elm-pages](https://elm-pages.com) `BackendTask` to build scripts to query and modify your data from the command line
- **Pure Elm** — no SQL, no ORMs, no serialization boilerplate

## How it works

Your `BackendModel` (defined in `src/Types.elm`) works just like in a regular Lamdera app. The only difference is that it is persisted to disk instead of a hosted Lamdera application for use in scripts (**not** full-stack real-time Lamdera apps, just use Lamdera if you need that). It is serialized to `db.bin`. Your scripts live in `script/` and can access the type-safe Lamdera database through two functions:

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
│   ├── Backend.elm             # Backend.init provides defaults
│   ├── Evergreen/
│   │   ├── V1/
│   │   │   └── Types.elm       # Snapshot of Types.elm at V1
│   │   └── Migrate/
│   │       └── V2.elm          # V1 → V2 migration
├── lib/
│   ├── LamderaDb.elm           # Library code — don't edit
│   └── SchemaVersion.elm       # Current schema version number
├── script/
│   ├── Example.elm             # Your scripts go here
│   └── Migrate.elm             # Migration runner
├── test.sh                     # E2E migration test
├── snapshot.sh                 # Schema snapshot helper
└── db.bin                      # Your data (gitignored)
```

## Getting started

1. Fork or clone this repo
2. Install dependencies:
   ```sh
   npm install
   ```
3. Define your `BackendModel` in `src/Types.elm`
4. Set initial values in `Backend.init` (`src/Backend.elm`)
5. Write scripts in `script/`

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
-- SCHEMA VERSION MISMATCH ---------------
db.bin is at version 1 but schema is version 2. Run: npx elm-pages run script/Migrate.elm
```

### Running a migration

```bash
npx elm-pages run script/Migrate.elm
```

On success:

```
Migrated db.bin from version 1 to version 2
```

### Full workflow for changing your schema

1. **Snapshot the current types** — this saves a copy of your types at the current version and bumps the version number:

   ```bash
   npm run schema:snapshot
   ```

   This creates:
   - `src/Evergreen/V{N}/Types.elm` — frozen snapshot of your current types
   - `src/Evergreen/Migrate/V{N+1}.elm` — migration stub to implement
   - Bumps `lib/SchemaVersion.elm` to N+1

2. **Change `src/Types.elm`** — make your schema changes (add fields, rename types, etc.)

3. **Implement the migration** — edit the generated `src/Evergreen/Migrate/V{N+1}.elm` to map old types to new:

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

4. **Wire it up in `script/Migrate.elm`** — add a branch for the new version in the migration runner's `case version of` expression.

5. **Run the migration:**

   ```bash
   npx elm-pages run script/Migrate.elm
   ```

### Testing migrations

The project includes an end-to-end migration test that replays the real user workflow:

```bash
npm test
```

This runs through 4 phases:
1. Seeds data using V1 types
2. Switches to V2 types and verifies that `LamderaDb.get` rejects the stale data
3. Runs the migration
4. Verifies all migrated field values are correct
