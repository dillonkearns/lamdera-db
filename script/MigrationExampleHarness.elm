module MigrationExampleHarness exposing (run)

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
    { init : Bool
    , runHarness : Bool
    , clean : Bool
    , force : Bool
    , version : Maybe String
    }


run : Script
run =
    Script.withCliOptions
        (Cli.Program.config
            |> Cli.Program.add
                (Cli.OptionsParser.build CliOptions
                    |> Cli.OptionsParser.with
                        (Cli.Option.flag "init"
                            |> Cli.Option.withDescription "Generate example harness file"
                        )
                    |> Cli.OptionsParser.with
                        (Cli.Option.flag "run"
                            |> Cli.Option.withDescription "Run example harness with elm-pages"
                        )
                    |> Cli.OptionsParser.with
                        (Cli.Option.flag "clean"
                            |> Cli.Option.withDescription "Delete generated harness file"
                        )
                    |> Cli.OptionsParser.with
                        (Cli.Option.flag "force"
                            |> Cli.Option.withDescription "Overwrite harness file when used with --init"
                        )
                    |> Cli.OptionsParser.with
                        (Cli.Option.optionalKeywordArg "version"
                            |> Cli.Option.withDescription "Target migration version (default: SchemaVersion.current)"
                        )
                    |> Cli.OptionsParser.end
                )
        )
        runHarness


runHarness : CliOptions -> BackendTask FatalError ()
runHarness options =
    let
        effectiveOptions =
            if not options.init && not options.runHarness && not options.clean then
                { options | init = True }

            else
                options
    in
    resolveVersion effectiveOptions.version
        |> BackendTask.andThen
            (\targetVersion ->
                if targetVersion < 2 then
                    BackendTask.fail
                        (FatalError.build
                            { title = "Invalid version"
                            , body = "Migration example harness requires version >= 2 (no previous snapshot for V1)."
                            }
                        )

                else
                    let
                        oldVersion =
                            targetVersion - 1

                        moduleName =
                            "MigrationExampleV" ++ String.fromInt targetVersion

                        scriptFile =
                            "script/" ++ moduleName ++ ".elm"

                        oldModule =
                            "Evergreen.V" ++ String.fromInt oldVersion ++ ".Types"

                        migrateModule =
                            "Evergreen.Migrate.V" ++ String.fromInt targetVersion
                    in
                    requireFile ("src/Evergreen/V" ++ String.fromInt oldVersion ++ "/Types.elm")
                        |> BackendTask.andThen (\_ -> requireFile ("src/Evergreen/Migrate/V" ++ String.fromInt targetVersion ++ ".elm"))
                        |> BackendTask.andThen
                            (\_ ->
                                let
                                    doInit =
                                        if effectiveOptions.init then
                                            initHarness effectiveOptions scriptFile moduleName oldModule migrateModule oldVersion targetVersion

                                        else
                                            BackendTask.succeed ()

                                    doRun =
                                        if effectiveOptions.runHarness then
                                            runHarnessFile scriptFile

                                        else
                                            BackendTask.succeed ()

                                    doClean =
                                        if effectiveOptions.clean then
                                            cleanHarness scriptFile

                                        else
                                            BackendTask.succeed ()
                                in
                                doInit
                                    |> BackendTask.andThen (\_ -> doRun)
                                    |> BackendTask.andThen (\_ -> doClean)
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
                    BackendTask.succeed v

                Nothing ->
                    BackendTask.fail
                        (FatalError.build
                            { title = "Invalid version"
                            , body = "--version must be an integer, got: " ++ versionStr
                            }
                        )


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


initHarness : CliOptions -> String -> String -> String -> String -> Int -> Int -> BackendTask FatalError ()
initHarness options scriptFile moduleName oldModule migrateModule oldVersion newVersion =
    LamderaDb.FileHelpers.fileExists scriptFile
        |> BackendTask.andThen
            (\exists ->
                if exists && not options.force then
                    Script.log ("Harness already exists: " ++ scriptFile)
                        |> BackendTask.andThen
                            (\_ ->
                                BackendTask.File.rawFile scriptFile
                                    |> BackendTask.allowFatal
                                    |> BackendTask.andThen
                                        (\content ->
                                            if String.contains "TODO_SAMPLE_BEFORE_MODEL" content || String.contains "Debug.todo" content then
                                                BackendTask.fail
                                                    (FatalError.build
                                                        { title = "Placeholders found"
                                                        , body = "Existing harness still has placeholders. Use --force to regenerate or edit the current file before --run."
                                                        }
                                                    )

                                            else
                                                Script.log "Use --force to overwrite."
                                        )
                            )

                else
                    Script.writeFile
                        { path = scriptFile
                        , body = renderTemplate moduleName oldModule migrateModule oldVersion newVersion
                        }
                        |> BackendTask.allowFatal
                        |> BackendTask.andThen (\_ -> Script.log ("Generated harness: " ++ scriptFile))
                        |> BackendTask.andThen
                            (\_ ->
                                Script.log ("Next: replace TODO_SAMPLE_BEFORE_MODEL with a concrete " ++ oldModule ++ ".BackendModel value.")
                            )
            )


runHarnessFile : String -> BackendTask FatalError ()
runHarnessFile scriptFile =
    requireFile scriptFile
        |> BackendTask.andThen
            (\_ ->
                BackendTask.File.rawFile scriptFile
                    |> BackendTask.allowFatal
                    |> BackendTask.andThen
                        (\content ->
                            if String.contains "TODO_SAMPLE_BEFORE_MODEL" content || String.contains "Debug.todo" content then
                                BackendTask.fail
                                    (FatalError.build
                                        { title = "Placeholders found"
                                        , body = "Harness still has placeholders. Fill sampleBefore before running."
                                        }
                                    )

                            else
                                Script.log ("Running migration example harness: " ++ scriptFile)
                                    |> BackendTask.andThen (\_ -> Script.exec "npx" [ "elm-pages", "run", scriptFile ])
                        )
            )


cleanHarness : String -> BackendTask FatalError ()
cleanHarness scriptFile =
    LamderaDb.FileHelpers.fileExists scriptFile
        |> BackendTask.andThen
            (\exists ->
                if exists then
                    LamderaDb.FileHelpers.deleteFile scriptFile
                        |> BackendTask.andThen (\_ -> Script.log ("Removed harness: " ++ scriptFile))

                else
                    Script.log ("No harness file to remove: " ++ scriptFile)
            )


renderTemplate : String -> String -> String -> Int -> Int -> String
renderTemplate moduleName oldModule migrateModule oldVersion newVersion =
    let
        oldVersionStr =
            String.fromInt oldVersion

        newVersionStr =
            String.fromInt newVersion
    in
    String.join "\n"
        [ "module " ++ moduleName ++ " exposing (run)"
        , ""
        , "import BackendTask exposing (BackendTask)"
        , "import Debug"
        , "import " ++ migrateModule ++ " as Migrate"
        , "import " ++ oldModule ++ " as Old"
        , "import FatalError exposing (FatalError)"
        , "import Pages.Script as Script exposing (Script)"
        , "import Types"
        , ""
        , ""
        , "type alias Assertion ="
        , "    { name : String"
        , "    , ok : Bool"
        , "    , details : String"
        , "    }"
        , ""
        , ""
        , "run : Script"
        , "run ="
        , "    Script.withoutCliOptions"
        , "        (let"
        , "            before ="
        , "                sampleBefore"
        , ""
        , "            after ="
        , "                Migrate.backendModel before"
        , ""
        , "            results ="
        , "                assertions before after"
        , ""
        , "            failed ="
        , "                List.filter (\\assertion -> not assertion.ok) results"
        , ""
        , "            summary ="
        , "                \"ASSERTION_SUMMARY: passed=\""
        , "                    ++ String.fromInt (List.length results - List.length failed)"
        , "                    ++ \" failed=\""
        , "                    ++ String.fromInt (List.length failed)"
        , "                    ++ \" total=\""
        , "                    ++ String.fromInt (List.length results)"
        , "         in"
        , "         Script.log (\"Before (V" ++ oldVersionStr ++ "):\\n\" ++ Debug.toString before)"
        , "            |> BackendTask.andThen (\\_ -> Script.log (\"After  (V" ++ newVersionStr ++ "):\\n\" ++ Debug.toString after))"
        , "            |> BackendTask.andThen (\\_ -> Script.log summary)"
        , "            |> BackendTask.andThen"
        , "                (\\_ ->"
        , "                    if List.isEmpty results then"
        , "                        Script.log \"No custom assertions defined yet. Add checks in assertions.\""
        , ""
        , "                    else if List.isEmpty failed then"
        , "                        Script.log \"Example assertions passed.\""
        , ""
        , "                    else"
        , "                        BackendTask.fail"
        , "                            (FatalError.build"
        , "                                { title = \"Example assertions failed\""
        , "                                , body ="
        , "                                    summary"
        , "                                        ++ \"\\n\""
        , "                                        ++ String.join \"\\n\" (List.map formatFailure failed)"
        , "                                }"
        , "                            )"
        , "                )"
        , "        )"
        , ""
        , ""
        , "sampleBefore : Old.BackendModel"
        , "sampleBefore ="
        , "    Debug.todo \"TODO_SAMPLE_BEFORE_MODEL\""
        , ""
        , ""
        , "assertions : Old.BackendModel -> Types.BackendModel -> List Assertion"
        , "assertions before after ="
        , "    -- Add explicit safety checks for important invariants."
        , "    -- Example checks to consider:"
        , "    --   * list lengths preserved"
        , "    --   * IDs unchanged"
        , "    --   * newly added fields have expected derived/default values"
        , "    let"
        , "        _ ="
        , "            ( before, after )"
        , "    in"
        , "    []"
        , ""
        , ""
        , "formatFailure : Assertion -> String"
        , "formatFailure assertion ="
        , "    \"- \" ++ assertion.name ++ \": \" ++ assertion.details"
        , ""
        ]
