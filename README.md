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

-- Get the current BackendModel. Loads from db.bin and Wire3-decodes it.
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
│   ├── Frontend.elm
│   └── Env.elm
├── lib/
│   └── LamderaDb.elm           # Library code — don't edit
├── script/
│   └── Example.elm             # Your scripts go here
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
                    | todos = model.todos ++ [ { id = model.nextId, title = "Buy milk", completed = False } ]
                    , nextId = model.nextId + 1
                }
            )
            |> BackendTask.andThen (\_ -> LamderaDb.get)
            |> BackendTask.andThen (\model -> Script.log ("Total todos: " ++ String.fromInt (List.length model.todos)))
        )
```

## Migrations

Migrations work as in a standard Lamdera project. When you change the type definition for your `BackendModel`, use the normal Lamdera workflow.

```bash
lamdera check    # Detects type changes, generates migration file
```

Edit the generated migration, then your scripts will work with the new model shape. If `db.bin` was saved with an old model version and can't be decoded, the script will fail with a clear error message — delete `db.bin` to start fresh from `Backend.init`.
