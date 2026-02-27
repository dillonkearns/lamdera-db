module LamderaDb.Lock exposing (withLock)

import BackendTask exposing (BackendTask)
import BackendTask.Custom
import FatalError exposing (FatalError)
import Json.Decode as Decode
import Json.Encode as Encode


acquireDbLock : BackendTask FatalError String
acquireDbLock =
    BackendTask.Custom.run "acquireDbLock"
        Encode.null
        Decode.string
        |> BackendTask.allowFatal
        |> BackendTask.quiet


releaseDbLock : String -> BackendTask FatalError ()
releaseDbLock token =
    BackendTask.Custom.run "releaseDbLock"
        (Encode.string token)
        (Decode.succeed ())
        |> BackendTask.allowFatal
        |> BackendTask.quiet


withLock : BackendTask FatalError a -> BackendTask FatalError a
withLock task =
    acquireDbLock
        |> BackendTask.andThen
            (\token ->
                task
                    |> BackendTask.toResult
                    |> BackendTask.andThen
                        (\result ->
                            releaseDbLock token
                                |> BackendTask.andThen
                                    (\_ ->
                                        case result of
                                            Ok value ->
                                                BackendTask.succeed value

                                            Err error ->
                                                BackendTask.fail error
                                    )
                        )
            )
