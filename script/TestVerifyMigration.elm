module TestVerifyMigration exposing (run)

import BackendTask exposing (BackendTask)
import FatalError exposing (FatalError)
import LamderaDb
import Pages.Script as Script exposing (Script)
import Types exposing (BackendModel, Todo)


run : Script
run =
    Script.withoutCliOptions
        (LamderaDb.get
            |> BackendTask.andThen verify
        )


verify : BackendModel -> BackendTask FatalError ()
verify model =
    let
        errors =
            [ if List.length model.todos /= 2 then
                Just ("Expected 2 todos, got " ++ String.fromInt (List.length model.todos))

              else
                Nothing
            , if model.nextId /= 3 then
                Just ("Expected nextId=3, got " ++ String.fromInt model.nextId)

              else
                Nothing
            ]
                ++ (case model.todos of
                        [ first, second ] ->
                            [ checkTodo "first" first 1 "Buy milk" False 0
                            , checkTodo "second" second 2 "Write tests" True 0
                            ]

                        _ ->
                            []
                   )
                |> List.filterMap identity
    in
    if List.isEmpty errors then
        Script.log "All migration checks passed!"

    else
        BackendTask.fail
            (FatalError.build
                { title = "Migration verification failed"
                , body = String.join "\n" errors
                }
            )


checkTodo : String -> Todo -> Int -> String -> Bool -> Int -> Maybe String
checkTodo label todo expectedId expectedTitle expectedCompleted expectedCreatedAt =
    let
        checks =
            [ if todo.id /= expectedId then
                Just (label ++ ": expected id=" ++ String.fromInt expectedId ++ ", got " ++ String.fromInt todo.id)

              else
                Nothing
            , if todo.title /= expectedTitle then
                Just (label ++ ": expected title=\"" ++ expectedTitle ++ "\", got \"" ++ todo.title ++ "\"")

              else
                Nothing
            , if todo.completed /= expectedCompleted then
                Just (label ++ ": expected completed=" ++ boolToString expectedCompleted ++ ", got " ++ boolToString todo.completed)

              else
                Nothing
            , if todo.createdAt /= expectedCreatedAt then
                Just (label ++ ": expected createdAt=" ++ String.fromInt expectedCreatedAt ++ ", got " ++ String.fromInt todo.createdAt)

              else
                Nothing
            ]
    in
    case List.filterMap identity checks of
        [] ->
            Nothing

        errs ->
            Just (String.join "; " errs)


boolToString : Bool -> String
boolToString b =
    if b then
        "True"

    else
        "False"
