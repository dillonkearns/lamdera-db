module LamderaDb exposing (get, update)

import Backend
import BackendTask exposing (BackendTask)
import BackendTask.Custom
import Base64
import Bytes exposing (Bytes)
import FatalError exposing (FatalError)
import Json.Decode as Decode
import Json.Encode as Encode
import Lamdera.Wire3 as Wire
import Types exposing (BackendModel)


get : BackendTask FatalError BackendModel
get =
    load
        |> BackendTask.andThen
            (\maybeBase64 ->
                case maybeBase64 of
                    Nothing ->
                        BackendTask.succeed (Tuple.first Backend.init)

                    Just b64 ->
                        case b64 |> Base64.toBytes |> Maybe.andThen (Wire.bytesDecode Types.w3_decode_BackendModel) of
                            Just model ->
                                BackendTask.succeed model

                            Nothing ->
                                BackendTask.fail
                                    (FatalError.build
                                        { title = "db.bin decode failed"
                                        , body = "Failed to decode db.bin. This can happen if your BackendModel type has changed since the last save. Delete db.bin to start fresh from Backend.init, or run Lamdera migrations first."
                                        }
                                    )
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
                case Base64.fromBytes bytes of
                    Just b64 ->
                        save b64

                    Nothing ->
                        BackendTask.fail
                            (FatalError.build
                                { title = "db.bin encode failed"
                                , body = "Failed to Base64-encode the BackendModel."
                                }
                            )
            )


load : BackendTask FatalError (Maybe String)
load =
    BackendTask.Custom.run "loadDbState"
        Encode.null
        (Decode.nullable Decode.string)
        |> BackendTask.allowFatal
        |> BackendTask.quiet


save : String -> BackendTask FatalError ()
save b64 =
    BackendTask.Custom.run "saveDbState"
        (Encode.string b64)
        (Decode.succeed ())
        |> BackendTask.allowFatal
        |> BackendTask.quiet
