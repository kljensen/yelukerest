module Msgs exposing (..)

import Assignments.Model exposing (Assignment)
import Auth.Model exposing (CurrentUser)
import Http
import Meetings.Model exposing (Meeting)
import Navigation exposing (Location)
import Players.Model exposing (Player, PlayerId)
import RemoteData exposing (WebData)


type Msg
    = OnFetchPlayers (WebData (List Player))
    | OnFetchMeetings (WebData (List Meeting))
    | OnFetchAssignments (WebData (List Assignment))
    | OnFetchCurrentUser (WebData CurrentUser)
    | OnLocationChange Location
    | ChangeLevel Player Int
    | OnPlayerSave (Result Http.Error Player)
