module Types exposing (..)

type alias BackendModel =
    { todos : List Todo
    , nextId : Int
    }


type alias Todo =
    { id : Int
    , title : String
    , completed : Bool
    , updatedAt : Int
    }
