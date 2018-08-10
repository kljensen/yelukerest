module Subscriptions exposing (subscriptions)

import Models exposing (Model)
import Msgs exposing (Msg)
import Time exposing (Time, second)


subscriptions : Model -> Sub Msg
subscriptions model =
    Time.every (5 * second) Msgs.Tick
