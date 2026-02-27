module MigrationContext exposing (run)

import BackendTask exposing (BackendTask)
import BackendTask.File
import BackendTask.Stream
import FatalError exposing (FatalError)
import LamderaDb.FileHelpers
import LamderaDb.Snapshot
import Pages.Script as Script exposing (Script)


run : Script
run =
    Script.withoutCliOptions
        (LamderaDb.Snapshot.parseSchemaVersion
            |> BackendTask.andThen displayContext
        )


displayContext : Int -> BackendTask FatalError ()
displayContext schemaVersion =
    let
        prevVersion =
            schemaVersion - 1

        migrationFile =
            "src/Evergreen/Migrate/V" ++ String.fromInt schemaVersion ++ ".elm"

        snapshotFile =
            if prevVersion >= 1 then
                Just ("src/Evergreen/V" ++ String.fromInt prevVersion ++ "/Types.elm")

            else
                Nothing
    in
    Script.log "# Evergreen Migration Context"
        |> BackendTask.andThen (\_ -> Script.log "")
        |> BackendTask.andThen (\_ -> Script.log ("SchemaVersion.current: " ++ String.fromInt schemaVersion))
        |> BackendTask.andThen
            (\_ ->
                case snapshotFile of
                    Just sf ->
                        Script.log ("Previous snapshot: " ++ sf)

                    Nothing ->
                        Script.log "Previous snapshot: <none for V1>"
            )
        |> BackendTask.andThen (\_ -> Script.log "Current types: src/Types.elm")
        |> BackendTask.andThen (\_ -> Script.log ("Target migration file: " ++ migrationFile))
        |> BackendTask.andThen (\_ -> Script.log "")
        |> BackendTask.andThen (\_ -> showDiff snapshotFile)
        |> BackendTask.andThen (\_ -> scanRiskMarkers migrationFile)


showDiff : Maybe String -> BackendTask FatalError ()
showDiff maybeSnapshotFile =
    case maybeSnapshotFile of
        Nothing ->
            Script.log "## Types Diff"
                |> BackendTask.andThen (\_ -> Script.log "(no previous snapshot file found)")
                |> BackendTask.andThen (\_ -> Script.log "")

        Just snapshotFile ->
            LamderaDb.FileHelpers.fileExists snapshotFile
                |> BackendTask.andThen
                    (\exists ->
                        if not exists then
                            Script.log "## Types Diff"
                                |> BackendTask.andThen (\_ -> Script.log "(no previous snapshot file found)")
                                |> BackendTask.andThen (\_ -> Script.log "")

                        else
                            Script.log "## Types Diff (previous snapshot -> current)"
                                |> BackendTask.andThen
                                    (\_ ->
                                        BackendTask.Stream.commandWithOptions
                                            (BackendTask.Stream.defaultCommandOptions
                                                |> BackendTask.Stream.allowNon0Status
                                            )
                                            "diff"
                                            [ "-u", snapshotFile, "src/Types.elm" ]
                                            |> BackendTask.Stream.read
                                            |> BackendTask.map
                                                (\{ body } ->
                                                    if String.trim body == "" then
                                                        "(no diff)"

                                                    else
                                                        body
                                                )
                                            |> BackendTask.onError (\_ -> BackendTask.succeed "(diff error)")
                                            |> BackendTask.allowFatal
                                    )
                                |> BackendTask.andThen Script.log
                                |> BackendTask.andThen (\_ -> Script.log "")
                    )


scanRiskMarkers : String -> BackendTask FatalError ()
scanRiskMarkers migrationFile =
    Script.log "## Migration Placeholder / Risky Marker Scan"
        |> BackendTask.andThen
            (\_ ->
                LamderaDb.FileHelpers.fileExists migrationFile
                    |> BackendTask.andThen
                        (\exists ->
                            if not exists then
                                Script.log "Migration file does not exist yet."

                            else
                                BackendTask.File.rawFile migrationFile
                                    |> BackendTask.allowFatal
                                    |> BackendTask.andThen
                                        (\content ->
                                            let
                                                markers =
                                                    [ "Unimplemented", "Debug.todo", "todo_implementMigration"
                                                    , "ModelReset", "ModelUnchanged", "MsgUnchanged", "MsgOldValueIgnored"
                                                    ]

                                                foundMarkers =
                                                    markers
                                                        |> List.filter (\marker -> String.contains marker content)
                                            in
                                            if List.isEmpty foundMarkers then
                                                Script.log "(none found)"

                                            else
                                                foundMarkers
                                                    |> List.map (\m -> Script.log ("  Found: " ++ m))
                                                    |> List.foldl (\task acc -> acc |> BackendTask.andThen (\_ -> task)) (BackendTask.succeed ())
                                        )
                        )
            )
