module Subscriptions exposing (subscriptions)

import Models exposing (Model)
import Msgs exposing (Msg)
import Time exposing (Time, second)
import SSE exposing (serverSideEvents)


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch [
        Time.every (5 * second) Msgs.Tick
        , serverSideEvents model.sse
    ]
