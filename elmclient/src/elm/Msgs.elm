module Msgs exposing (..)

import Auth.Model exposing (CurrentUser)
import Http
import Meetings.Model exposing (Meeting)
import Navigation exposing (Location)
import Players.Model exposing (Player, PlayerId)
import RemoteData exposing (WebData)


type Msg
    = OnFetchPlayers (WebData (List Player))
    | OnFetchMeetings (WebData (List Meeting))
    | OnFetchCurrentUser (WebData CurrentUser)
    | OnLocationChange Location
    | ChangeLevel Player Int
    | OnPlayerSave (Result Http.Error Player)
