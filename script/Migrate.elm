module Migrate exposing (run)

import BackendTask exposing (BackendTask)
import Evergreen.Migrate.V2 as MigrateV2
import Evergreen.V1.Types
import FatalError exposing (FatalError)
import LamderaDb.Migration
import Lamdera.Wire3 as Wire
import Pages.Script as Script exposing (Script)
import SchemaVersion
import Types


run : Script
run =
    Script.withoutCliOptions
        (LamderaDb.Migration.readVersioned
            |> BackendTask.andThen
                (\{ version, bytes } ->
                    case version of
                        1 ->
                            case Wire.bytesDecode Evergreen.V1.Types.w3_decode_BackendModel bytes of
                                Just v1Model ->
                                    migrateFromV1 v1Model

                                Nothing ->
                                    BackendTask.fail
                                        (FatalError.build
                                            { title = "V1 decode failed"
                                            , body = "Could not decode db.bin as V1 BackendModel."
                                            }
                                        )

                        _ ->
                            if version == SchemaVersion.current then
                                Script.log ("db.bin is already at version " ++ String.fromInt version ++ ". No migration needed.")

                            else
                                BackendTask.fail
                                    (FatalError.build
                                        { title = "Unknown version"
                                        , body = "db.bin is at version " ++ String.fromInt version ++ " but no migration path is defined."
                                        }
                                    )
                )
        )


migrateFromV1 : Evergreen.V1.Types.BackendModel -> BackendTask FatalError ()
migrateFromV1 model =
    let
        currentModel =
            MigrateV2.backendModel model
    in
    saveAndLog currentModel


saveAndLog : Types.BackendModel -> BackendTask FatalError ()
saveAndLog currentModel =
    let
        bytes =
            Wire.bytesEncode (Types.w3_encode_BackendModel currentModel)
    in
    LamderaDb.Migration.writeVersioned SchemaVersion.current bytes
        |> BackendTask.andThen
            (\_ ->
                Script.log
                    ("Migrated db.bin to version "
                        ++ String.fromInt SchemaVersion.current
                    )
            )
