module Models exposing (..)

import Meetings.Model exposing (Meeting)
import Players.Model exposing (Player, PlayerId)
import RemoteData exposing (WebData)


type alias Model =
    { players : WebData (List Player)
    , route : Route
    , meetings : WebData (List Meeting)
    }


initialModel : Route -> Model
initialModel route =
    { players = RemoteData.Loading
    , route = route
    , meetings = RemoteData.Loading
    }


type Route
    = PlayersRoute
    | PlayerRoute PlayerId
    | NotFoundRoute
