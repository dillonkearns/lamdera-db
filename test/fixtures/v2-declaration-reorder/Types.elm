module Types exposing (..)


type alias Todo =
    { id : Int
    , title : String
    , completed : Bool
    , createdAt : Int
    }


initialBackendModel : BackendModel
initialBackendModel =
    { todos = []
    , nextId = 1
    }


type alias BackendModel =
    { todos : List Todo
    , nextId : Int
    }
