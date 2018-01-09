module Models exposing (..)

import Players.Model exposing (Player, PlayerId)
import RemoteData exposing (WebData)


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
