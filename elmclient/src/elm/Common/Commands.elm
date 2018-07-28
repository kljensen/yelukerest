module Common.Commands exposing (..)

import Date exposing (Date)
import Msgs exposing (Msg)
import Task


fetchDate : Cmd Msg
fetchDate =
    Date.now
        |> Task.perform Msgs.OnFetchDate
