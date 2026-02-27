module LamderaDb.DeepCompare exposing (DeepCompareResult(..), compareBackendModelShape)

import BackendTask exposing (BackendTask)
import BackendTask.Stream
import FatalError exposing (FatalError)
import LamderaDb.FileHelpers
import Pages.Script as Script


type DeepCompareResult
    = Same
    | Different
    | DeepCheckError String


compareBackendModelShape : { storedTypes : String, currentTypes : String } -> BackendTask FatalError DeepCompareResult
compareBackendModelShape { storedTypes, currentTypes } =
    let
        tmpTypes =
            ".lamdera-db/LamderaDbDeepCheckTmpTypes.elm"

        tmpWitness =
            ".lamdera-db/LamderaDbDeepCheckTmpWitness.elm"

        witnessContent =
            String.join "\n"
                [ "module LamderaDbDeepCheckTmpWitness exposing (main)"
                , ""
                , "import LamderaDbDeepCheckTmpTypes exposing (..)"
                , "import Platform"
                , ""
                , "main ="
                , "    Platform.worker"
                , "        { init = \\() -> ( w3_encode_BackendModel, Cmd.none )"
                , "        , update = \\_ m -> ( m, Cmd.none )"
                , "        , subscriptions = \\_ -> Sub.none"
                , "        }"
                , ""
                ]
    in
    LamderaDb.FileHelpers.mkTempDir
        |> BackendTask.andThen
            (\tmpDir ->
                compileAndHash tmpTypes tmpWitness witnessContent storedTypes (tmpDir ++ "/stored.js")
                    |> BackendTask.andThen
                        (\storedResult ->
                            case storedResult of
                                Err msg ->
                                    cleanup tmpTypes tmpWitness tmpDir
                                        |> BackendTask.map (\_ -> DeepCheckError ("Failed to compile stored types: " ++ msg))

                                Ok storedHash ->
                                    compileAndHash tmpTypes tmpWitness witnessContent currentTypes (tmpDir ++ "/current.js")
                                        |> BackendTask.andThen
                                            (\currentResult ->
                                                cleanup tmpTypes tmpWitness tmpDir
                                                    |> BackendTask.map
                                                        (\_ ->
                                                            case currentResult of
                                                                Err msg ->
                                                                    DeepCheckError ("Failed to compile current types: " ++ msg)

                                                                Ok currentHash ->
                                                                    if storedHash == currentHash then
                                                                        Same

                                                                    else
                                                                        Different
                                                        )
                                            )
                        )
            )


compileAndHash : String -> String -> String -> String -> String -> BackendTask FatalError (Result String String)
compileAndHash tmpTypes tmpWitness witnessContent typesSource outputJs =
    let
        moduleContent =
            typesSource
                |> String.lines
                |> List.map
                    (\line ->
                        if String.startsWith "module Types" line then
                            "module LamderaDbDeepCheckTmpTypes" ++ String.dropLeft (String.length "module Types") line

                        else
                            line
                    )
                |> String.join "\n"
    in
    Script.writeFile { path = tmpTypes, body = moduleContent }
        |> BackendTask.allowFatal
        |> BackendTask.andThen
            (\_ ->
                Script.writeFile { path = tmpWitness, body = witnessContent }
                    |> BackendTask.allowFatal
            )
        |> BackendTask.andThen
            (\_ ->
                BackendTask.Stream.commandWithOptions
                    (BackendTask.Stream.defaultCommandOptions
                        |> BackendTask.Stream.withOutput BackendTask.Stream.MergeStderrAndStdout
                    )
                    "lamdera"
                    [ "make", ".lamdera-db/LamderaDbDeepCheckTmpWitness.elm", "--output=" ++ outputJs ]
                    |> BackendTask.Stream.read
                    |> BackendTask.map (\_ -> True)
                    |> BackendTask.onError (\_ -> BackendTask.succeed False)
                    |> BackendTask.allowFatal
                    |> BackendTask.andThen
                        (\compiled ->
                            if not compiled then
                                BackendTask.succeed (Err "Compilation failed")

                            else
                                Script.command "shasum" [ "-a", "256", outputJs ]
                                    |> BackendTask.map
                                        (\output ->
                                            output
                                                |> String.trim
                                                |> String.split " "
                                                |> List.head
                                                |> Maybe.withDefault ""
                                                |> Ok
                                        )
                        )
            )


cleanup : String -> String -> String -> BackendTask FatalError ()
cleanup tmpTypes tmpWitness tmpDir =
    LamderaDb.FileHelpers.deleteFile tmpTypes
        |> BackendTask.andThen (\_ -> LamderaDb.FileHelpers.deleteFile tmpWitness)
        |> BackendTask.andThen (\_ -> LamderaDb.FileHelpers.deleteDir tmpDir)
