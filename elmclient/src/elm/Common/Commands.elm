module Common.Commands exposing (updateDate)

import Msgs exposing (Msg)
import Task
import Time exposing (Time)


updateDate : Cmd Msg
updateDate =
    Time.now
        |> Task.perform Msgs.Tick
