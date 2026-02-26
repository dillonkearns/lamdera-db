module LamderaDb exposing (get, update)

import Backend
import BackendTask exposing (BackendTask)
import BackendTask.Custom
import BackendTask.File
import Base64
import FatalError exposing (FatalError)
import Json.Decode as Decode
import Json.Encode as Encode
import LamderaDb.Migration
import Lamdera.Wire3 as Wire
import SchemaVersion
import Types exposing (BackendModel)


get : BackendTask FatalError BackendModel
get =
    BackendTask.map2 Tuple.pair load readTypesElm
        |> BackendTask.andThen
            (\( maybeJson, currentTypes ) ->
                case maybeJson of
                    Nothing ->
                        BackendTask.succeed (Tuple.first Backend.init)

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
                                                    ++ ". Run: npx elm-pages run script/Migrate.elm"
                                            }
                                        )

                                else
                                    case envelope.t of
                                        Just storedTypes ->
                                            if storedTypes /= currentTypes then
                                                BackendTask.fail
                                                    (FatalError.build
                                                        { title = "Types.elm has changed"
                                                        , body = "src/Types.elm has changed since db.bin was last written, but SchemaVersion is still " ++ String.fromInt SchemaVersion.current ++ ". Run: npx elm-pages run script/Migrate.elm"
                                                        }
                                                    )

                                            else
                                                decodeModel envelope.d

                                        Nothing ->
                                            -- Old db.bin without types fingerprint; skip check
                                            decodeModel envelope.d
            )


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
    BackendTask.Custom.run "loadDbState"
        Encode.null
        (Decode.nullable Decode.string)
        |> BackendTask.allowFatal
        |> BackendTask.quiet
