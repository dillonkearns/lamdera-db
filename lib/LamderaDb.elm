module LamderaDb exposing (get, update)

import Backend
import BackendTask exposing (BackendTask)
import BackendTask.Custom
import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import FatalError exposing (FatalError)
import Json.Decode as Decode
import Json.Encode as Encode
import Lamdera.Wire3 as Wire
import Types exposing (BackendModel)


get : BackendTask FatalError BackendModel
get =
    load
        |> BackendTask.andThen
            (\maybeInts ->
                case maybeInts of
                    Nothing ->
                        BackendTask.succeed (Tuple.first Backend.init)

                    Just ints ->
                        case ints |> intListToBytes |> Maybe.andThen (Wire.bytesDecode Types.w3_decode_BackendModel) of
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
                save (bytesToIntList bytes)
            )


load : BackendTask FatalError (Maybe (List Int))
load =
    BackendTask.Custom.run "loadDbState"
        Encode.null
        (Decode.nullable (Decode.list Decode.int))
        |> BackendTask.allowFatal
        |> BackendTask.quiet


save : List Int -> BackendTask FatalError ()
save intList =
    BackendTask.Custom.run "saveDbState"
        (Encode.list Encode.int intList)
        (Decode.succeed ())
        |> BackendTask.allowFatal
        |> BackendTask.quiet



-- Internal helpers: convert Bytes <-> List Int for JSON transport


bytesToIntList : Bytes -> List Int
bytesToIntList bytes =
    let
        width =
            Bytes.width bytes

        decoder =
            Bytes.Decode.loop ( width, [] )
                (\( remaining, acc ) ->
                    if remaining <= 0 then
                        Bytes.Decode.succeed (Bytes.Decode.Done (List.reverse acc))

                    else
                        Bytes.Decode.map
                            (\byte -> Bytes.Decode.Loop ( remaining - 1, byte :: acc ))
                            Bytes.Decode.unsignedInt8
                )
    in
    Bytes.Decode.decode decoder bytes
        |> Maybe.withDefault []


intListToBytes : List Int -> Maybe Bytes
intListToBytes ints =
    ints
        |> List.map Bytes.Encode.unsignedInt8
        |> Bytes.Encode.sequence
        |> Bytes.Encode.encode
        |> Just
