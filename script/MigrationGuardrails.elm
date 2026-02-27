module MigrationGuardrails exposing (run)

import BackendTask exposing (BackendTask)
import BackendTask.File
import Cli.Option
import Cli.OptionsParser
import Cli.Program
import FatalError exposing (FatalError)
import LamderaDb.FileHelpers
import LamderaDb.Snapshot
import Pages.Script as Script exposing (Script)


type alias CliOptions =
    { allowReset : Bool
    , full : Bool
    , version : Maybe String
    }


run : Script
run =
    Script.withCliOptions
        (Cli.Program.config
            |> Cli.Program.add
                (Cli.OptionsParser.build CliOptions
                    |> Cli.OptionsParser.with
                        (Cli.Option.flag "allow-reset"
                            |> Cli.Option.withDescription "Allow ModelReset in migration"
                        )
                    |> Cli.OptionsParser.with
                        (Cli.Option.flag "full"
                            |> Cli.Option.withDescription "Run full test suite after checks"
                        )
                    |> Cli.OptionsParser.with
                        (Cli.Option.optionalKeywordArg "version"
                            |> Cli.Option.withDescription "Target migration version (default: SchemaVersion.current)"
                        )
                    |> Cli.OptionsParser.end
                )
        )
        runGuardrails


runGuardrails : CliOptions -> BackendTask FatalError ()
runGuardrails options =
    requireFiles
        |> BackendTask.andThen
            (\_ ->
                resolveVersion options.version
                    |> BackendTask.andThen (checkMigration options)
            )


requireFiles : BackendTask FatalError ()
requireFiles =
    requireFile ".lamdera-db/SchemaVersion.elm"
        |> BackendTask.andThen (\_ -> requireFile "src/Types.elm")
        |> BackendTask.andThen (\_ -> requireFile ".lamdera-db/Migrate.elm")


requireFile : String -> BackendTask FatalError ()
requireFile path =
    LamderaDb.FileHelpers.fileExists path
        |> BackendTask.andThen
            (\exists ->
                if exists then
                    BackendTask.succeed ()

                else
                    BackendTask.fail
                        (FatalError.build
                            { title = "Missing file"
                            , body = "Missing file: " ++ path
                            }
                        )
            )


resolveVersion : Maybe String -> BackendTask FatalError Int
resolveVersion maybeVersion =
    case maybeVersion of
        Nothing ->
            LamderaDb.Snapshot.parseSchemaVersion

        Just versionStr ->
            case String.toInt versionStr of
                Just v ->
                    if v < 1 then
                        BackendTask.fail
                            (FatalError.build
                                { title = "Invalid version"
                                , body = "--version must be >= 1, got: " ++ versionStr
                                }
                            )

                    else
                        BackendTask.succeed v

                Nothing ->
                    BackendTask.fail
                        (FatalError.build
                            { title = "Invalid version"
                            , body = "--version must be an integer, got: " ++ versionStr
                            }
                        )


checkMigration : CliOptions -> Int -> BackendTask FatalError ()
checkMigration options targetVersion =
    let
        migrationFile =
            "src/Evergreen/Migrate/V" ++ String.fromInt targetVersion ++ ".elm"
    in
    requireFile migrationFile
        |> BackendTask.andThen
            (\_ ->
                if targetVersion > 1 then
                    requireFile ("src/Evergreen/V" ++ String.fromInt (targetVersion - 1) ++ "/Types.elm")

                else
                    BackendTask.succeed ()
            )
        |> BackendTask.andThen (\_ -> Script.log ("Checking migration file: " ++ migrationFile))
        |> BackendTask.andThen
            (\_ ->
                BackendTask.File.rawFile migrationFile
                    |> BackendTask.allowFatal
            )
        |> BackendTask.andThen (validateContent options targetVersion migrationFile)
        |> BackendTask.andThen (\_ -> compileFiles targetVersion)
        |> BackendTask.andThen
            (\_ ->
                if options.full then
                    Script.log "Running full test suite..."
                        |> BackendTask.andThen (\_ -> Script.exec "npm" [ "test" ])

                else
                    BackendTask.succeed ()
            )
        |> BackendTask.andThen (\_ -> Script.log "Migration guardrails passed.")


validateContent : CliOptions -> Int -> String -> String -> BackendTask FatalError ()
validateContent options _ _ content =
    let
        hasPlaceholders =
            String.contains "Unimplemented" content
                || String.contains "Debug.todo" content
                || String.contains "todo_implementMigration" content

        hasUnchanged =
            String.contains "ModelUnchanged" content
                || String.contains "MsgUnchanged" content

        hasReset =
            String.contains "ModelReset" content
    in
    if hasPlaceholders then
        BackendTask.fail
            (FatalError.build
                { title = "Placeholders found"
                , body = "Migration still has placeholders."
                }
            )

    else if hasUnchanged then
        BackendTask.fail
            (FatalError.build
                { title = "Unchanged markers"
                , body = "Migration uses ModelUnchanged/MsgUnchanged. Use explicit migration logic."
                }
            )

    else if hasReset && not options.allowReset then
        BackendTask.fail
            (FatalError.build
                { title = "ModelReset found"
                , body = "Migration uses ModelReset. Re-run with --allow-reset only if explicitly intended."
                }
            )

    else
        BackendTask.succeed ()


compileFiles : Int -> BackendTask FatalError ()
compileFiles targetVersion =
    Script.log "Compiling migration scripts..."
        |> BackendTask.andThen (\_ -> Script.exec "npx" [ "lamdera", "make", ".lamdera-db/Migrate.elm", "--output=/dev/null" ])
        |> BackendTask.andThen
            (\_ ->
                LamderaDb.FileHelpers.fileExists ".lamdera-db/MigrateChain.elm"
                    |> BackendTask.andThen
                        (\exists ->
                            if exists then
                                Script.exec "npx" [ "lamdera", "make", ".lamdera-db/MigrateChain.elm", "--output=/dev/null" ]

                            else
                                BackendTask.succeed ()
                        )
            )
        |> BackendTask.andThen
            (\_ ->
                LamderaDb.FileHelpers.fileExists "script/SeedDb.elm"
                    |> BackendTask.andThen
                        (\exists ->
                            if exists then
                                Script.exec "npx" [ "lamdera", "make", "script/SeedDb.elm", "--output=/dev/null" ]

                            else
                                BackendTask.succeed ()
                        )
            )
        |> BackendTask.andThen
            (\_ ->
                LamderaDb.FileHelpers.fileExists "script/TestVerifyMigration.elm"
                    |> BackendTask.andThen
                        (\exists ->
                            if exists then
                                Script.exec "npx" [ "lamdera", "make", "script/TestVerifyMigration.elm", "--output=/dev/null" ]

                            else
                                BackendTask.succeed ()
                        )
            )
