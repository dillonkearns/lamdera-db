module Types exposing (..)

type alias BackendModel =
    { todos : List Todo
    , nextId : Int
    }


type alias Todo =
    { id : Int
    , title : String
    , completed : Bool
    , createdAt : Int
    }


type alias CliUiPrefs =
    { darkMode : Bool
    }


initialBackendModel : BackendModel
initialBackendModel =
    { todos = []
    , nextId = 1
    }
