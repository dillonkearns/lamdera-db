module Evergreen.Migrate.V3 exposing (backendModel)

import Evergreen.V2.Types
import Types


backendModel : Evergreen.V2.Types.BackendModel -> Types.BackendModel
backendModel old =
    { todos =
        List.map
            (\todo ->
                { id = todo.id
                , title = todo.title
                , completed = todo.completed
                , createdAt = todo.createdAt
                , priority = 0
                }
            )
            old.todos
    , nextId = old.nextId
    }
