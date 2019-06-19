module Subscriptions exposing (subscriptions)

import Models exposing (Model)
import Msgs exposing (Msg)
import SSE exposing (serverSideEvents)
import Time exposing (Time, second)


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every (5 * second) Msgs.Tick
        , serverSideEvents model.sse
        ]
