module MigrationTest exposing (run)

import BackendTask exposing (BackendTask)
import FatalError exposing (FatalError)
import LamderaDb
import Pages.Script as Script exposing (Script)


run : Script
run =
    Script.withoutCliOptions
        (LamderaDb.get
            |> BackendTask.andThen
                (\model ->
                    Script.log
                        ("BackendModel loaded! todos: "
                            ++ String.fromInt (List.length model.todos)
                            ++ ", nextId: "
                            ++ String.fromInt model.nextId
                        )
                )
        )
