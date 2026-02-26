module LamderaDb.Migration exposing (readVersioned, writeVersioned)

import BackendTask exposing (BackendTask)
import BackendTask.Custom
import BackendTask.File
import Base64
import Bytes exposing (Bytes)
import FatalError exposing (FatalError)
import Json.Decode as Decode
import Json.Encode as Encode


readVersioned : BackendTask FatalError { version : Int, bytes : Bytes }
readVersioned =
    load
        |> BackendTask.andThen
            (\maybeJson ->
                case maybeJson of
                    Nothing ->
                        BackendTask.fail
                            (FatalError.build
                                { title = "No db.bin found"
                                , body = "Cannot read versioned data: db.bin does not exist."
                                }
                            )

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
                                case Base64.toBytes envelope.d of
                                    Just bytes ->
                                        BackendTask.succeed { version = envelope.v, bytes = bytes }

                                    Nothing ->
                                        BackendTask.fail
                                            (FatalError.build
                                                { title = "db.bin base64 decode failed"
                                                , body = "Could not decode the base64 data in db.bin."
                                                }
                                            )
            )


writeVersioned : Int -> Bytes -> BackendTask FatalError ()
writeVersioned version bytes =
    readTypesElm
        |> BackendTask.andThen
            (\typesContent ->
                case Base64.fromBytes bytes of
                    Just b64 ->
                        let
                            json =
                                Encode.encode 0
                                    (Encode.object
                                        [ ( "v", Encode.int version )
                                        , ( "t", Encode.string typesContent )
                                        , ( "d", Encode.string b64 )
                                        ]
                                    )
                        in
                        save json

                    Nothing ->
                        BackendTask.fail
                            (FatalError.build
                                { title = "db.bin encode failed"
                                , body = "Failed to Base64-encode the model bytes."
                                }
                            )
            )


envelopeDecoder : Decode.Decoder { v : Int, d : String }
envelopeDecoder =
    Decode.map2 (\v d -> { v = v, d = d })
        (Decode.field "v" Decode.int)
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


save : String -> BackendTask FatalError ()
save json =
    BackendTask.Custom.run "saveDbState"
        (Encode.string json)
        (Decode.succeed ())
        |> BackendTask.allowFatal
        |> BackendTask.quiet
