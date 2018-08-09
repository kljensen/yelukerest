module Subscriptions exposing (subscriptions)

import Models exposing (Model)
import Msgs exposing (Msg)
import Time exposing (Time, second)


subscriptions : Model -> Sub Msg
subscriptions model =
    Time.every second Msgs.Tick
