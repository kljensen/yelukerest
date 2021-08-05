module Subscriptions exposing (subscriptions)

import Models exposing (Model)
import Msgs exposing (Msg)
import SSE exposing (serverSideEvents)
import Time exposing (Posix)


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every 500000 Msgs.Tick
        , serverSideEvents model.sse
        ]
