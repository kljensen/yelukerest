module Models exposing (..)

import Assignments.Model exposing (Assignment, AssignmentSlug)
import Auth.Model exposing (CurrentUser)
import Meetings.Model exposing (Meeting, MeetingSlug)
import Players.Model exposing (Player, PlayerId)
import RemoteData exposing (WebData)


type alias Model =
    { players : WebData (List Player)
    , route : Route
    , meetings : WebData (List Meeting)
    , currentUser : WebData CurrentUser
    , assignments : WebData (List Assignment)
    }


initialModel : Route -> Model
initialModel route =
    { players = RemoteData.Loading
    , route = route
    , meetings = RemoteData.Loading
    , currentUser = RemoteData.Loading
    , assignments = RemoteData.NotAsked
    }


type Route
    = PlayersRoute
    | IndexRoute
    | CurrentUserDashboardRoute
    | PlayerRoute PlayerId
    | MeetingListRoute
    | MeetingDetailRoute MeetingSlug
    | AssignmentListRoute
    | AssignmentDetailRoute AssignmentSlug
    | NotFoundRoute
