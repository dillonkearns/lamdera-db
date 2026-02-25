module Example exposing (run)

import BackendTask
import LamderaDb
import Pages.Script as Script exposing (Script)


run : Script
run =
    Script.withoutCliOptions
        (LamderaDb.update
            (\model ->
                { model
                    | todos =
                        model.todos
                            ++ [ { id = model.nextId
                                 , title = "Buy milk"
                                 , completed = False
                                 }
                               ]
                    , nextId = model.nextId + 1
                }
            )
            |> BackendTask.andThen (\_ -> LamderaDb.get)
            |> BackendTask.andThen
                (\model ->
                    model.todos
                        |> List.map
                            (\t ->
                                (if t.completed then
                                    "[x] "

                                 else
                                    "[ ] "
                                )
                                    ++ t.title
                            )
                        |> String.join "\n"
                        |> Script.log
                )
        )
