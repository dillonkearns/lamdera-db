module Backend exposing (init)

import Types exposing (BackendModel)


init : ( BackendModel, Cmd msg )
init =
    ( { todos = [], nextId = 1 }
    , Cmd.none
    )
