module Types exposing (..)

import Browser exposing (UrlRequest)
import Browser.Navigation exposing (Key)
import Url exposing (Url)


type alias FrontendModel =
    { key : Key
    , message : String
    , darkMode : Bool
    }


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


type FrontendMsg
    = UrlClicked UrlRequest
    | UrlChanged Url
    | NoOpFrontendMsg


type ToBackend
    = NoOpToBackend


type BackendMsg
    = NoOpBackendMsg


type ToFrontend
    = NoOpToFrontend
