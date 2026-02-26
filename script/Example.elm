module Example exposing (run)

import BackendTask exposing (BackendTask)
import FatalError exposing (FatalError)
import LamderaDb
import Pages.Script as Script exposing (Script)


run : Script
run =
    LamderaDb.script loop


loop : BackendTask FatalError ()
loop =
    LamderaDb.get
        |> BackendTask.andThen
            (\model ->
                printTodos model
                    |> BackendTask.andThen
                        (\_ ->
                            Script.log "\n(a)dd  (t)oggle  (d)elete  (q)uit"
                                |> BackendTask.andThen (\_ -> Script.readKey)
                        )
                    |> BackendTask.andThen (\key -> handleInput key model.todos)
            )


printTodos : { a | todos : List { b | id : Int, title : String, completed : Bool } } -> BackendTask FatalError ()
printTodos model =
    let
        todoLines =
            if List.isEmpty model.todos then
                "  (no items)"

            else
                model.todos
                    |> List.indexedMap
                        (\i t ->
                            let
                                check =
                                    if t.completed then
                                        "[x]"

                                    else
                                        "[ ]"
                            in
                            "  " ++ String.fromInt (i + 1) ++ ". " ++ check ++ " " ++ t.title
                        )
                    |> String.join "\n"
    in
    Script.log ("\n--- To-Do List ---\n" ++ todoLines)


handleInput : String -> List { a | id : Int } -> BackendTask FatalError ()
handleInput key todos =
    let
        idAtDisplayNum n =
            todos |> List.drop (n - 1) |> List.head |> Maybe.map .id
    in
    case key of
        "a" ->
            Script.question "Title: "
                |> BackendTask.andThen
                    (\title ->
                        LamderaDb.update
                            (\m ->
                                { m
                                    | todos =
                                        m.todos
                                            ++ [ { id = m.nextId
                                                 , title = title
                                                 , completed = False
                                                 , createdAt = 0
                                                 , description = ""
                                                 }
                                               ]
                                    , nextId = m.nextId + 1
                                }
                            )
                    )
                |> BackendTask.andThen (\_ -> loop)

        "t" ->
            Script.log "Toggle item #: "
                |> BackendTask.andThen (\_ -> Script.readKey)
                |> BackendTask.andThen
                    (\numKey ->
                        case String.toInt numKey |> Maybe.andThen idAtDisplayNum of
                            Just id ->
                                LamderaDb.update
                                    (\m ->
                                        { m
                                            | todos =
                                                List.map
                                                    (\t ->
                                                        if t.id == id then
                                                            { t | completed = not t.completed }

                                                        else
                                                            t
                                                    )
                                                    m.todos
                                        }
                                    )
                                    |> BackendTask.andThen (\_ -> loop)

                            Nothing ->
                                Script.log "Invalid number."
                                    |> BackendTask.andThen (\_ -> loop)
                    )

        "d" ->
            Script.log "Delete item #: "
                |> BackendTask.andThen (\_ -> Script.readKey)
                |> BackendTask.andThen
                    (\numKey ->
                        case String.toInt numKey |> Maybe.andThen idAtDisplayNum of
                            Just id ->
                                LamderaDb.update
                                    (\m ->
                                        { m
                                            | todos =
                                                List.filter (\t -> t.id /= id) m.todos
                                        }
                                    )
                                    |> BackendTask.andThen (\_ -> loop)

                            Nothing ->
                                Script.log "Invalid number."
                                    |> BackendTask.andThen (\_ -> loop)
                    )

        "q" ->
            Script.log "Bye!"

        _ ->
            Script.log ("Unknown command: " ++ key)
                |> BackendTask.andThen (\_ -> loop)
