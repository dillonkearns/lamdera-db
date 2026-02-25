module Evergreen.Migrate.V2 exposing (backendModel)

import Evergreen.V1.Types
import Types


backendModel : Evergreen.V1.Types.BackendModel -> Types.BackendModel
backendModel old =
    { todos =
        List.map
            (\todo ->
                { id = todo.id
                , title = todo.title
                , completed = todo.completed
                , createdAt = 0
                }
            )
            old.todos
    , nextId = old.nextId
    }
