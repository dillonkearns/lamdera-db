module LamderaDb.Snapshot exposing (parseSchemaVersion, runSnapshot)

import BackendTask exposing (BackendTask)
import BackendTask.File
import FatalError exposing (FatalError)
import Json.Decode as Decode
import LamderaDb.FileHelpers
import Pages.Script as Script


type alias SnapshotResult =
    { previousVersion : Int
    , newVersion : Int
    }


runSnapshot : BackendTask FatalError SnapshotResult
runSnapshot =
    parseSchemaVersion
        |> BackendTask.andThen
            (\n ->
                let
                    k =
                        n + 1
                in
                guardPendingMigration n
                    |> BackendTask.andThen (\_ -> getTypesForSnapshot)
                    |> BackendTask.andThen (\typesContent -> createSnapshot n typesContent)
                    |> BackendTask.andThen (\_ -> rewriteMigrationImports n)
                    |> BackendTask.andThen (\_ -> createMigrationStub n k)
                    |> BackendTask.andThen (\_ -> writeMigrateChain n)
                    |> BackendTask.andThen (\_ -> writeSchemaVersion k)
                    |> BackendTask.map (\_ -> { previousVersion = n, newVersion = k })
            )



-- Schema version parsing


parseSchemaVersion : BackendTask FatalError Int
parseSchemaVersion =
    BackendTask.File.rawFile ".lamdera-db/SchemaVersion.elm"
        |> BackendTask.allowFatal
        |> BackendTask.andThen
            (\content ->
                case extractVersion content of
                    Just n ->
                        BackendTask.succeed n

                    Nothing ->
                        BackendTask.fail
                            (FatalError.build
                                { title = "Parse error"
                                , body = "Could not parse version from .lamdera-db/SchemaVersion.elm"
                                }
                            )
            )


extractVersion : String -> Maybe Int
extractVersion content =
    content
        |> String.lines
        |> List.filterMap
            (\line ->
                if String.contains "current" line then
                    Nothing

                else
                    line |> String.trim |> String.toInt
            )
        |> List.head



-- Guard against pending migration


guardPendingMigration : Int -> BackendTask FatalError ()
guardPendingMigration n =
    LamderaDb.FileHelpers.fileExists "db.bin"
        |> BackendTask.andThen
            (\exists ->
                if not exists then
                    BackendTask.succeed ()

                else
                    BackendTask.File.rawFile "db.bin"
                        |> BackendTask.allowFatal
                        |> BackendTask.andThen
                            (\raw ->
                                case Decode.decodeString (Decode.field "v" Decode.int) raw of
                                    Ok v ->
                                        if v /= n then
                                            BackendTask.fail
                                                (FatalError.build
                                                    { title = "Pending migration"
                                                    , body =
                                                        "There is a pending migration: db.bin is at version "
                                                            ++ String.fromInt v
                                                            ++ " but SchemaVersion is "
                                                            ++ String.fromInt n
                                                            ++ ". Run the migration first: npm run migrate"
                                                    }
                                                )

                                        else
                                            BackendTask.succeed ()

                                    Err _ ->
                                        BackendTask.succeed ()
                            )
            )



-- Get types content for snapshot (prefer stored types from db.bin)


getTypesForSnapshot : BackendTask FatalError String
getTypesForSnapshot =
    BackendTask.File.rawFile "db.bin"
        |> BackendTask.map Just
        |> BackendTask.onError (\_ -> BackendTask.succeed Nothing)
        |> BackendTask.allowFatal
        |> BackendTask.andThen
            (\maybeRaw ->
                case maybeRaw of
                    Just raw ->
                        case Decode.decodeString (Decode.maybe (Decode.field "t" Decode.string)) raw of
                            Ok (Just stored) ->
                                BackendTask.succeed stored

                            _ ->
                                readCurrentTypes

                    Nothing ->
                        readCurrentTypes
            )


readCurrentTypes : BackendTask FatalError String
readCurrentTypes =
    BackendTask.File.rawFile "src/Types.elm"
        |> BackendTask.allowFatal



-- Create snapshot file


createSnapshot : Int -> String -> BackendTask FatalError ()
createSnapshot n typesContent =
    let
        nStr =
            String.fromInt n

        snapshotContent =
            typesContent
                |> String.lines
                |> List.map
                    (\line ->
                        if String.startsWith "module Types" line then
                            "module Evergreen.V" ++ nStr ++ ".Types" ++ String.dropLeft (String.length "module Types") line

                        else
                            line
                    )
                |> String.join "\n"
    in
    Script.writeFile
        { path = "src/Evergreen/V" ++ nStr ++ "/Types.elm"
        , body = snapshotContent
        }
        |> BackendTask.allowFatal



-- Rewrite existing migration imports


rewriteMigrationImports : Int -> BackendTask FatalError ()
rewriteMigrationImports n =
    let
        nStr =
            String.fromInt n

        migratePath =
            "src/Evergreen/Migrate/V" ++ nStr ++ ".elm"
    in
    LamderaDb.FileHelpers.fileExists migratePath
        |> BackendTask.andThen
            (\exists ->
                if not exists then
                    BackendTask.succeed ()

                else
                    BackendTask.File.rawFile migratePath
                        |> BackendTask.allowFatal
                        |> BackendTask.andThen
                            (\content ->
                                let
                                    updated =
                                        content
                                            |> String.lines
                                            |> List.map
                                                (\line ->
                                                    if line == "import Types" || String.startsWith "import Types " line then
                                                        String.replace "import Types" ("import Evergreen.V" ++ nStr ++ ".Types as Types") line

                                                    else
                                                        line
                                                )
                                            |> String.join "\n"
                                in
                                Script.writeFile { path = migratePath, body = updated }
                                    |> BackendTask.allowFatal
                            )
            )



-- Create migration stub with compile-error sentinel


createMigrationStub : Int -> Int -> BackendTask FatalError ()
createMigrationStub n k =
    let
        nStr =
            String.fromInt n

        kStr =
            String.fromInt k

        content =
            String.join "\n"
                [ "module Evergreen.Migrate.V" ++ kStr ++ " exposing (backendModel)"
                , ""
                , "import Evergreen.V" ++ nStr ++ ".Types"
                , "import Types"
                , ""
                , ""
                , "backendModel : Evergreen.V" ++ nStr ++ ".Types.BackendModel -> Types.BackendModel"
                , "backendModel old ="
                , "    todo_implementMigration_V" ++ nStr ++ "_to_V" ++ kStr
                , ""
                ]
    in
    Script.writeFile
        { path = "src/Evergreen/Migrate/V" ++ kStr ++ ".elm"
        , body = content
        }
        |> BackendTask.allowFatal



-- Generate and write MigrateChain.elm


writeMigrateChain : Int -> BackendTask FatalError ()
writeMigrateChain n =
    Script.writeFile
        { path = ".lamdera-db/MigrateChain.elm"
        , body = generateMigrateChainElm n
        }
        |> BackendTask.allowFatal


generateMigrateChainElm : Int -> String
generateMigrateChainElm n =
    let
        k =
            n + 1

        migrateImports =
            List.range 2 k
                |> List.map (\i -> "import Evergreen.Migrate.V" ++ String.fromInt i ++ " as MigrateV" ++ String.fromInt i)

        snapshotImports =
            List.range 1 n
                |> List.map (\i -> "import Evergreen.V" ++ String.fromInt i ++ ".Types")

        imports =
            [ "import BackendTask exposing (BackendTask)" ]
                ++ migrateImports
                ++ snapshotImports
                ++ [ "import FatalError exposing (FatalError)"
                   , "import LamderaDb.FileHelpers"
                   , "import LamderaDb.Migration"
                   , "import Lamdera.Wire3 as Wire"
                   , "import Pages.Script as Script exposing (Script)"
                   , "import SchemaVersion"
                   , "import Types"
                   ]

        caseBranches =
            List.range 1 n
                |> List.map caseBranch
                |> String.join "\n\n"

        chainFunctions =
            List.range 1 n
                |> List.map
                    (\i ->
                        if i < n then
                            passthroughChain i (i + 1)

                        else
                            finalChain i k
                    )
                |> String.join ""
    in
    String.join "\n"
        [ "module MigrateChain exposing (run)"
        , ""
        , String.join "\n" imports
        , ""
        , ""
        , "run : Script"
        , "run ="
        , "    Script.withoutCliOptions"
        , "        (backupDbBin"
        , "            |> BackendTask.andThen (\\_ -> runMigration)"
        , "        )"
        , ""
        , ""
        , "backupDbBin : BackendTask FatalError ()"
        , "backupDbBin ="
        , "    LamderaDb.FileHelpers.fileExists \"db.bin\""
        , "        |> BackendTask.andThen"
        , "            (\\exists ->"
        , "                if exists then"
        , "                    LamderaDb.FileHelpers.copyFile { from = \"db.bin\", to = \"db.bin.backup\" }"
        , ""
        , "                else"
        , "                    BackendTask.succeed ()"
        , "            )"
        , "        |> BackendTask.quiet"
        , ""
        , ""
        , "runMigration : BackendTask FatalError ()"
        , "runMigration ="
        , "    LamderaDb.Migration.readVersioned"
        , "        |> BackendTask.andThen"
        , "            (\\{ version, bytes } ->"
        , "                case version of"
        , caseBranches
        , ""
        , "                    _ ->"
        , "                        if version == SchemaVersion.current then"
        , "                            Script.log (\"db.bin is already at version \" ++ String.fromInt version ++ \". No migration needed.\")"
        , ""
        , "                        else"
        , "                            BackendTask.fail"
        , "                                (FatalError.build"
        , "                                    { title = \"Unknown version\""
        , "                                    , body = \"db.bin is at version \" ++ String.fromInt version ++ \" but no migration path is defined.\""
        , "                                    }"
        , "                                )"
        , "            )"
        , chainFunctions
        , ""
        , ""
        , "saveAndLog : Types.BackendModel -> BackendTask FatalError ()"
        , "saveAndLog currentModel ="
        , "    let"
        , "        bytes ="
        , "            Wire.bytesEncode (Types.w3_encode_BackendModel currentModel)"
        , "    in"
        , "    LamderaDb.Migration.writeVersioned SchemaVersion.current bytes"
        , "        |> BackendTask.andThen"
        , "            (\\_ ->"
        , "                Script.log"
        , "                    (\"Migrated db.bin to version \""
        , "                        ++ String.fromInt SchemaVersion.current"
        , "                    )"
        , "            )"
        , ""
        ]



-- Write SchemaVersion.elm


writeSchemaVersion : Int -> BackendTask FatalError ()
writeSchemaVersion version =
    Script.writeFile
        { path = ".lamdera-db/SchemaVersion.elm"
        , body =
            String.join "\n"
                [ "module SchemaVersion exposing (current)"
                , ""
                , ""
                , "current : Int"
                , "current ="
                , "    " ++ String.fromInt version
                , ""
                ]
        }
        |> BackendTask.allowFatal



-- String builders for MigrateChain.elm generation


caseBranch : Int -> String
caseBranch i =
    let
        iStr =
            String.fromInt i
    in
    String.join "\n"
        [ "                    " ++ iStr ++ " ->"
        , "                        case Wire.bytesDecode Evergreen.V" ++ iStr ++ ".Types.w3_decode_BackendModel bytes of"
        , "                            Just v" ++ iStr ++ "Model ->"
        , "                                migrateFromV" ++ iStr ++ " v" ++ iStr ++ "Model"
        , ""
        , "                            Nothing ->"
        , "                                BackendTask.fail"
        , "                                    (FatalError.build"
        , "                                        { title = \"V" ++ iStr ++ " decode failed\""
        , "                                        , body = \"Could not decode db.bin as V" ++ iStr ++ " BackendModel.\""
        , "                                        }"
        , "                                    )"
        ]


passthroughChain : Int -> Int -> String
passthroughChain i next =
    let
        iStr =
            String.fromInt i

        nextStr =
            String.fromInt next
    in
    String.join "\n"
        [ ""
        , ""
        , "migrateFromV" ++ iStr ++ " : Evergreen.V" ++ iStr ++ ".Types.BackendModel -> BackendTask FatalError ()"
        , "migrateFromV" ++ iStr ++ " model ="
        , "    migrateFromV" ++ nextStr ++ " (MigrateV" ++ nextStr ++ ".backendModel model)"
        ]


finalChain : Int -> Int -> String
finalChain i k =
    let
        iStr =
            String.fromInt i

        kStr =
            String.fromInt k
    in
    String.join "\n"
        [ ""
        , ""
        , "migrateFromV" ++ iStr ++ " : Evergreen.V" ++ iStr ++ ".Types.BackendModel -> BackendTask FatalError ()"
        , "migrateFromV" ++ iStr ++ " model ="
        , "    let"
        , "        currentModel ="
        , "            MigrateV" ++ kStr ++ ".backendModel model"
        , "    in"
        , "    saveAndLog currentModel"
        ]
