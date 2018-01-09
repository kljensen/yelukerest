module Msgs exposing (..)

import Http
import Meetings.Model exposing (Meeting)
import Navigation exposing (Location)
import Players.Model exposing (Player, PlayerId)
import RemoteData exposing (WebData)


type Msg
    = OnFetchPlayers (WebData (List Player))
    | OnFetchMeetings (WebData (List Meeting))
    | OnLocationChange Location
    | ChangeLevel Player Int
    | OnPlayerSave (Result Http.Error Player)
