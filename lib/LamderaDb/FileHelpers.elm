module LamderaDb.FileHelpers exposing (copyFile, deleteDir, deleteFile, fileExists, mkTempDir)

import BackendTask exposing (BackendTask)
import BackendTask.Glob
import FatalError exposing (FatalError)
import Pages.Script as Script


fileExists : String -> BackendTask FatalError Bool
fileExists path =
    BackendTask.Glob.fromString path
        |> BackendTask.map (\matches -> not (List.isEmpty matches))


copyFile : { from : String, to : String } -> BackendTask FatalError ()
copyFile { from, to } =
    Script.exec "cp" [ from, to ]


deleteFile : String -> BackendTask FatalError ()
deleteFile path =
    Script.exec "rm" [ "-f", path ]


deleteDir : String -> BackendTask FatalError ()
deleteDir path =
    Script.exec "rm" [ "-rf", path ]


mkTempDir : BackendTask FatalError String
mkTempDir =
    Script.command "mktemp" [ "-d" ]
        |> BackendTask.map String.trim
