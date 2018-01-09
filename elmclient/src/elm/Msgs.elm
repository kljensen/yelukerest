module Msgs exposing (..)

import Http
import Navigation exposing (Location)
import Players.Model exposing (Player, PlayerId)
import RemoteData exposing (WebData)


type Msg
    = OnFetchPlayers (WebData (List Player))
    | OnLocationChange Location
    | ChangeLevel Player Int
    | OnPlayerSave (Result Http.Error Player)
