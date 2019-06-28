module Common.Commands exposing (getTimeZone, getTimeZoneName, updateDate)

import Msgs exposing (Msg)
import Task
import Time


updateDate : Cmd Msg
updateDate =
    Time.now
        |> Task.perform Msgs.Tick


getTimeZone : Cmd Msg
getTimeZone =
    Task.perform Msgs.OnFetchTimeZone Time.here


getTimeZoneName : Cmd Msg
getTimeZoneName =
    Task.perform Msgs.OnFetchTimeZoneName Time.getZoneName
