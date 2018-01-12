module Models exposing (..)

import Auth.Model exposing (CurrentUser)
import Meetings.Model exposing (Meeting, MeetingSlug)
import Players.Model exposing (Player, PlayerId)
import RemoteData exposing (WebData)


type alias Model =
    { players : WebData (List Player)
    , route : Route
    , meetings : WebData (List Meeting)
    , currentUser : WebData CurrentUser
    }


initialModel : Route -> Model
initialModel route =
    { players = RemoteData.Loading
    , route = route
    , meetings = RemoteData.Loading
    , currentUser = RemoteData.Loading
    }


type Route
    = PlayersRoute
    | IndexRoute
    | CurrentUserDashboardRoute
    | PlayerRoute PlayerId
    | MeetingListRoute
    | MeetingDetailRoute MeetingSlug
    | NotFoundRoute
