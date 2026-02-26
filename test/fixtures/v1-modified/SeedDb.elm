module SeedDb exposing (run)

import BackendTask exposing (BackendTask)
import FatalError exposing (FatalError)
import LamderaDb
import Pages.Script as Script exposing (Script)


run : Script
run =
    LamderaDb.script
        (LamderaDb.update
            (\model ->
                { model
                    | todos =
                        [ { id = 1, title = "Buy milk", completed = False, updatedAt = 0 }
                        , { id = 2, title = "Write tests", completed = True, updatedAt = 0 }
                        ]
                    , nextId = 3
                }
            )
            |> BackendTask.andThen (\_ -> Script.log "Seeded db.bin with 2 todos.")
        )
