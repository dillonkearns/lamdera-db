module Types exposing (..)

-- BackendModel stores the application state
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
