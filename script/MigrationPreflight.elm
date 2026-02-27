module MigrationPreflight exposing (run)

import BackendTask exposing (BackendTask)
import BackendTask.Stream
import Cli.Option
import Cli.OptionsParser
import Cli.Program
import FatalError exposing (FatalError)
import LamderaDb.FileHelpers
import Pages.Script as Script exposing (Script)


type alias CliOptions =
    { applySnapshot : Bool
    }


type State
    = Ready
    | NoDb
    | NeedMigrate
    | NeedSnapshot
    | SnapshotApplied
    | UnknownError


run : Script
run =
    Script.withCliOptions
        (Cli.Program.config
            |> Cli.Program.add
                (Cli.OptionsParser.build CliOptions
                    |> Cli.OptionsParser.with
                        (Cli.Option.flag "apply-snapshot"
                            |> Cli.Option.withDescription "If snapshot is required, run npm run migrate automatically"
                        )
                    |> Cli.OptionsParser.end
                )
        )
        runPreflight


runPreflight : CliOptions -> BackendTask FatalError ()
runPreflight options =
    LamderaDb.FileHelpers.fileExists "script/MigrationTest.elm"
        |> BackendTask.andThen
            (\testExists ->
                if not testExists then
                    BackendTask.fail
                        (FatalError.build
                            { title = "Missing file"
                            , body = "Missing file: script/MigrationTest.elm"
                            }
                        )

                else
                    LamderaDb.FileHelpers.fileExists ".lamdera-db/Migrate.elm"
                        |> BackendTask.andThen
                            (\migrateExists ->
                                if not migrateExists then
                                    BackendTask.fail
                                        (FatalError.build
                                            { title = "Missing file"
                                            , body = "Missing file: .lamdera-db/Migrate.elm"
                                            }
                                        )

                                else
                                    checkDbAndRun options
                            )
            )


checkDbAndRun : CliOptions -> BackendTask FatalError ()
checkDbAndRun options =
    LamderaDb.FileHelpers.fileExists "db.bin"
        |> BackendTask.andThen
            (\exists ->
                if not exists then
                    Script.log "STATE: NO_DB"
                        |> BackendTask.andThen
                            (\_ ->
                                Script.log "No db.bin found. Snapshot need cannot be inferred from persisted data."
                                    |> BackendTask.andThen
                                        (\_ -> Script.log "If you changed BackendModel and want to start a new migration step, run: npm run migrate")
                            )

                else
                    runMigrationTest
                        |> BackendTask.andThen (handleResult options)
            )


runMigrationTest : BackendTask FatalError { succeeded : Bool, output : String }
runMigrationTest =
    Script.log "Running migration preflight..."
        |> BackendTask.andThen
            (\_ ->
                BackendTask.Stream.commandWithOptions
                    (BackendTask.Stream.defaultCommandOptions
                        |> BackendTask.Stream.allowNon0Status
                        |> BackendTask.Stream.withOutput BackendTask.Stream.MergeStderrAndStdout
                    )
                    "npx"
                    [ "elm-pages", "run", "script/MigrationTest.elm" ]
                    |> BackendTask.Stream.read
                    |> BackendTask.map (\{ body } -> { succeeded = True, output = body })
                    |> BackendTask.onError
                        (\{ recoverable } ->
                            case recoverable of
                                BackendTask.Stream.CustomError _ maybeBody ->
                                    BackendTask.succeed
                                        { succeeded = False
                                        , output = Maybe.withDefault "" maybeBody
                                        }

                                BackendTask.Stream.StreamError msg ->
                                    BackendTask.succeed
                                        { succeeded = False
                                        , output = msg
                                        }
                        )
                    |> BackendTask.allowFatal
            )


handleResult : CliOptions -> { succeeded : Bool, output : String } -> BackendTask FatalError ()
handleResult options { succeeded, output } =
    if succeeded then
        Script.log "STATE: READY"
            |> BackendTask.andThen (\_ -> Script.log "No pending snapshot/migration detected.")

    else
        let
            lowerOutput =
                String.toLower output
        in
        Script.log output
            |> BackendTask.andThen
                (\_ ->
                    if String.contains "schema version mismatch" lowerOutput then
                        Script.log "STATE: NEED_MIGRATE"
                            |> BackendTask.andThen (\_ -> Script.log "Run: npm run migrate")

                    else if String.contains "types.elm has changed" lowerOutput then
                        if options.applySnapshot then
                            Script.log "STATE: NEED_SNAPSHOT"
                                |> BackendTask.andThen (\_ -> Script.log "Applying snapshot via npm run migrate...")
                                |> BackendTask.andThen (\_ -> Script.exec "npm" [ "run", "migrate" ])
                                |> BackendTask.andThen (\_ -> Script.log "STATE: SNAPSHOT_APPLIED")

                        else
                            Script.log "STATE: NEED_SNAPSHOT"
                                |> BackendTask.andThen (\_ -> Script.log "Run: npm run migrate")

                    else
                        Script.log "STATE: UNKNOWN_ERROR"
                            |> BackendTask.andThen (\_ -> Script.log "Could not classify migration state from MigrationTest output.")
                )
