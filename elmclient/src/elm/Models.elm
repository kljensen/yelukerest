module Models exposing (..)

import RemoteData exposing (WebData)
import Players.Model exposing (PlayerId, Player)

type alias Model =
    { players : WebData (List Player)
    , route : Route
    }


initialModel : Route -> Model
initialModel route =
    { players = RemoteData.Loading
    , route = route
    }


type Route
    = PlayersRoute
    | PlayerRoute PlayerId
    | NotFoundRoute
