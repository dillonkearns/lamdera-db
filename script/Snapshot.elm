module Snapshot exposing (run)

import BackendTask
import BackendTask.Custom
import FatalError
import Json.Decode as Decode
import Json.Encode as Encode
import Pages.Script as Script exposing (Script)


run : Script
run =
    Script.withoutCliOptions
        (BackendTask.Custom.run "runSnapshot"
            Encode.null
            resultDecoder
            |> BackendTask.allowFatal
            |> BackendTask.andThen
                (\result ->
                    Script.log
                        ("Snapshot complete: V"
                            ++ String.fromInt result.previousVersion
                            ++ " -> V"
                            ++ String.fromInt result.newVersion
                            ++ "\nFiles: "
                            ++ String.join ", " result.files
                        )
                )
        )


resultDecoder : Decode.Decoder { previousVersion : Int, newVersion : Int, files : List String }
resultDecoder =
    Decode.map3 (\pv nv f -> { previousVersion = pv, newVersion = nv, files = f })
        (Decode.field "previousVersion" Decode.int)
        (Decode.field "newVersion" Decode.int)
        (Decode.field "files" (Decode.list Decode.string))
