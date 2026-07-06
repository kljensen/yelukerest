module Subscriptions exposing (subscriptions)

import Models exposing (Model)
import Msgs exposing (Msg)
import Time exposing (Posix)


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ Time.every 5000 Msgs.Tick
        ]
