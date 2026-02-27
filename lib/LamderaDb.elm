module LamderaDb exposing (get, script, update)

import BackendTask exposing (BackendTask)
import BackendTask.Custom
import BackendTask.File
import Base64
import FatalError exposing (FatalError)
import Json.Decode as Decode
import Json.Encode as Encode
import LamderaDb.DeepCompare exposing (DeepCompareResult(..))
import LamderaDb.Lock
import LamderaDb.Migration
import Lamdera.Wire3 as Wire
import Pages.Script as Script exposing (Script)
import SchemaVersion
import Types exposing (BackendModel, initialBackendModel)


script : BackendTask FatalError () -> Script
script task =
    Script.withoutCliOptions
        (LamderaDb.Lock.withLock
            (checkMigration
                |> BackendTask.andThen (\_ -> task)
            )
        )


get : BackendTask FatalError BackendModel
get =
    BackendTask.map2 Tuple.pair load readTypesElm
        |> BackendTask.andThen
            (\( maybeJson, currentTypes ) ->
                case maybeJson of
                    Nothing ->
                        BackendTask.succeed initialBackendModel

                    Just json ->
                        case Decode.decodeString envelopeDecoder json of
                            Err decodeErr ->
                                BackendTask.fail
                                    (FatalError.build
                                        { title = "db.bin envelope decode failed"
                                        , body = "Could not parse db.bin JSON envelope: " ++ Decode.errorToString decodeErr
                                        }
                                    )

                            Ok envelope ->
                                if envelope.v /= SchemaVersion.current then
                                    BackendTask.fail
                                        (FatalError.build
                                            { title = "Schema version mismatch"
                                            , body =
                                                "db.bin is at version "
                                                    ++ String.fromInt envelope.v
                                                    ++ " but schema is version "
                                                    ++ String.fromInt SchemaVersion.current
                                                    ++ ". Run: npm run migrate"
                                            }
                                        )

                                else
                                    case envelope.t of
                                        Just storedTypes ->
                                            verifyTypes currentTypes storedTypes (decodeModel envelope.d)

                                        Nothing ->
                                            -- Old db.bin without types fingerprint; skip check
                                            decodeModel envelope.d
            )


update : (BackendModel -> BackendModel) -> BackendTask FatalError ()
update fn =
    get
        |> BackendTask.andThen
            (\model ->
                let
                    newModel =
                        fn model

                    bytes =
                        Wire.bytesEncode (Types.w3_encode_BackendModel newModel)
                in
                LamderaDb.Migration.writeVersioned SchemaVersion.current bytes
            )


{-| Check for pending migrations without loading the model.
Reads the db.bin envelope and compares version + Types.elm fingerprint.
-}
checkMigration : BackendTask FatalError ()
checkMigration =
    BackendTask.map2 Tuple.pair load readTypesElm
        |> BackendTask.andThen
            (\( maybeJson, currentTypes ) ->
                case maybeJson of
                    Nothing ->
                        -- No db.bin yet, nothing to check
                        BackendTask.succeed ()

                    Just json ->
                        case Decode.decodeString envelopeDecoder json of
                            Err _ ->
                                -- Envelope is corrupt; get will report the details
                                BackendTask.succeed ()

                            Ok envelope ->
                                if envelope.v /= SchemaVersion.current then
                                    BackendTask.fail
                                        (FatalError.build
                                            { title = "Schema version mismatch"
                                            , body =
                                                "db.bin is at version "
                                                    ++ String.fromInt envelope.v
                                                    ++ " but schema is version "
                                                    ++ String.fromInt SchemaVersion.current
                                                    ++ ". Run: npm run migrate"
                                            }
                                        )

                                else
                                    case envelope.t of
                                        Just storedTypes ->
                                            verifyTypes currentTypes storedTypes (BackendTask.succeed ())

                                        Nothing ->
                                            BackendTask.succeed ()
            )


verifyTypes : String -> String -> BackendTask FatalError a -> BackendTask FatalError a
verifyTypes currentTypes storedTypes onSame =
    if storedTypes == currentTypes then
        onSame

    else
        deepCompare storedTypes currentTypes
            |> BackendTask.andThen
                (\result ->
                    case result of
                        Same ->
                            updateTypesFingerprint currentTypes
                                |> BackendTask.andThen (\_ -> onSame)

                        Different ->
                            BackendTask.fail
                                (FatalError.build
                                    { title = "Types.elm has changed"
                                    , body = "BackendModel has changed since db.bin was last written, but SchemaVersion is still " ++ String.fromInt SchemaVersion.current ++ ". Run: npm run migrate"
                                    }
                                )

                        DeepCheckError message ->
                            BackendTask.fail
                                (FatalError.build
                                    { title = "Could not verify schema compatibility"
                                    , body = message
                                    }
                                )
                )


{-| Explicitly update the stored types fingerprint in db.bin so that
subsequent reads hit the fast path (text equality) and skip the deep check.
Called after a deep compare confirms the types are structurally identical.
-}
updateTypesFingerprint : String -> BackendTask FatalError ()
updateTypesFingerprint currentTypes =
    load
        |> BackendTask.andThen
            (\maybeJson ->
                case maybeJson of
                    Nothing ->
                        BackendTask.succeed ()

                    Just json ->
                        case Decode.decodeString envelopeDecoder json of
                            Err _ ->
                                BackendTask.succeed ()

                            Ok envelope ->
                                let
                                    updatedJson =
                                        Encode.encode 0
                                            (Encode.object
                                                [ ( "v", Encode.int envelope.v )
                                                , ( "t", Encode.string currentTypes )
                                                , ( "d", Encode.string envelope.d )
                                                ]
                                            )
                                in
                                BackendTask.Custom.run "atomicSaveDbState"
                                    (Encode.string updatedJson)
                                    (Decode.succeed ())
                                    |> BackendTask.allowFatal
                                    |> BackendTask.quiet
            )


deepCompare : String -> String -> BackendTask FatalError DeepCompareResult
deepCompare storedTypes currentTypes =
    LamderaDb.DeepCompare.compareBackendModelShape
        { storedTypes = storedTypes
        , currentTypes = currentTypes
        }


decodeModel : String -> BackendTask FatalError BackendModel
decodeModel b64 =
    case b64 |> Base64.toBytes |> Maybe.andThen (Wire.bytesDecode Types.w3_decode_BackendModel) of
        Just model ->
            BackendTask.succeed model

        Nothing ->
            BackendTask.fail
                (FatalError.build
                    { title = "db.bin decode failed"
                    , body = "Failed to decode db.bin data. The Wire3 codec could not decode the stored bytes."
                    }
                )


envelopeDecoder : Decode.Decoder { v : Int, t : Maybe String, d : String }
envelopeDecoder =
    Decode.map3 (\v t d -> { v = v, t = t, d = d })
        (Decode.field "v" Decode.int)
        (Decode.maybe (Decode.field "t" Decode.string))
        (Decode.field "d" Decode.string)


readTypesElm : BackendTask FatalError String
readTypesElm =
    BackendTask.File.rawFile "src/Types.elm"
        |> BackendTask.allowFatal


load : BackendTask FatalError (Maybe String)
load =
    BackendTask.File.rawFile "db.bin"
        |> BackendTask.map Just
        |> BackendTask.onError (\_ -> BackendTask.succeed Nothing)
        |> BackendTask.allowFatal
        |> BackendTask.quiet
