module Migrate exposing (run)

import BackendTask exposing (BackendTask)
import BackendTask.File
import FatalError exposing (FatalError)
import Json.Decode as Decode
import LamderaDb.DeepCompare exposing (DeepCompareResult(..))
import LamderaDb.Snapshot
import Pages.Script as Script exposing (Script)
import SchemaVersion


type AutoSnapshotResult
    = NoDb
    | UpToDate
    | SnapshotCreated { previousVersion : Int, newVersion : Int }
    | MigrationPending


run : Script
run =
    Script.withoutCliOptions
        (checkAndAutoSnapshot
            |> BackendTask.andThen
                (\result ->
                    case result of
                        NoDb ->
                            Script.log "No db.bin found. Nothing to migrate."

                        UpToDate ->
                            Script.log "Already up to date. No migration needed."

                        SnapshotCreated { newVersion } ->
                            Script.log
                                ("Snapshot created. Edit src/Evergreen/Migrate/V"
                                    ++ String.fromInt newVersion
                                    ++ ".elm to implement the migration, then run: npm run migrate"
                                )

                        MigrationPending ->
                            runMigrationChain
                )
        )


checkAndAutoSnapshot : BackendTask FatalError AutoSnapshotResult
checkAndAutoSnapshot =
    loadDbState
        |> BackendTask.andThen
            (\maybeJson ->
                case maybeJson of
                    Nothing ->
                        BackendTask.succeed NoDb

                    Just json ->
                        case Decode.decodeString envelopeDecoder json of
                            Err _ ->
                                BackendTask.fail
                                    (FatalError.build
                                        { title = "db.bin parse error"
                                        , body = "Could not parse db.bin JSON envelope."
                                        }
                                    )

                            Ok envelope ->
                                if envelope.v /= SchemaVersion.current then
                                    BackendTask.succeed MigrationPending

                                else
                                    checkTypesChanged envelope.t
            )


checkTypesChanged : Maybe String -> BackendTask FatalError AutoSnapshotResult
checkTypesChanged maybeStoredTypes =
    case maybeStoredTypes of
        Nothing ->
            BackendTask.succeed UpToDate

        Just storedTypes ->
            BackendTask.File.rawFile "src/Types.elm"
                |> BackendTask.allowFatal
                |> BackendTask.andThen
                    (\currentTypes ->
                        if storedTypes == currentTypes then
                            BackendTask.succeed UpToDate

                        else
                            deepCompare storedTypes currentTypes
                                |> BackendTask.andThen
                                    (\compareResult ->
                                        case compareResult of
                                            Same ->
                                                BackendTask.succeed UpToDate

                                            Different ->
                                                callRunSnapshot
                                                    |> BackendTask.map
                                                        (\r ->
                                                            SnapshotCreated
                                                                { previousVersion = r.previousVersion
                                                                , newVersion = r.newVersion
                                                                }
                                                        )

                                            DeepCheckError msg ->
                                                BackendTask.fail
                                                    (FatalError.build
                                                        { title = "Could not verify schema compatibility"
                                                        , body = msg
                                                        }
                                                    )
                                    )
                    )



-- Auto-snapshot helpers


loadDbState : BackendTask FatalError (Maybe String)
loadDbState =
    BackendTask.File.rawFile "db.bin"
        |> BackendTask.map Just
        |> BackendTask.onError (\_ -> BackendTask.succeed Nothing)
        |> BackendTask.allowFatal
        |> BackendTask.quiet


callRunSnapshot : BackendTask FatalError { previousVersion : Int, newVersion : Int }
callRunSnapshot =
    LamderaDb.Snapshot.runSnapshot


runMigrationChain : BackendTask FatalError ()
runMigrationChain =
    Script.exec "npx" [ "elm-pages", "run", ".lamdera-db/MigrateChain.elm" ]


deepCompare : String -> String -> BackendTask FatalError DeepCompareResult
deepCompare storedTypes currentTypes =
    LamderaDb.DeepCompare.compareBackendModelShape
        { storedTypes = storedTypes
        , currentTypes = currentTypes
        }


envelopeDecoder : Decode.Decoder { v : Int, t : Maybe String, d : String }
envelopeDecoder =
    Decode.map3 (\v t d -> { v = v, t = t, d = d })
        (Decode.field "v" Decode.int)
        (Decode.maybe (Decode.field "t" Decode.string))
        (Decode.field "d" Decode.string)
