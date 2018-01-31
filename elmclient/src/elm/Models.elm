module Models exposing (..)

import Assignments.Model exposing (Assignment, AssignmentSlug, AssignmentSubmission)
import Auth.Model exposing (CurrentUser)
import Date exposing (Date)
import Meetings.Model exposing (Meeting, MeetingSlug)
import Players.Model exposing (Player, PlayerId)
import Quizzes.Model exposing (Quiz)
import RemoteData exposing (WebData)


type alias Flags =
    { courseTitle : String
    , piazzaURL : Maybe String
    }


type alias UIElements =
    { courseTitle : String
    , piazzaURL : Maybe String
    }


type alias Model =
    { current_date : Maybe Date
    , players : WebData (List Player)
    , route : Route
    , meetings : WebData (List Meeting)
    , currentUser : WebData CurrentUser
    , assignments : WebData (List Assignment)
    , quizzes : WebData (List Quiz)
    , uiElements : UIElements
    , assignmentSubmissions : WebData (List AssignmentSubmission)
    }


initialModel : Flags -> Route -> Model
initialModel flags route =
    { current_date = Nothing
    , players = RemoteData.Loading
    , route = route
    , meetings = RemoteData.Loading
    , currentUser = RemoteData.Loading
    , assignments = RemoteData.NotAsked
    , quizzes = RemoteData.NotAsked
    , uiElements =
        { courseTitle = flags.courseTitle
        , piazzaURL = flags.piazzaURL
        }
    , assignmentSubmissions = RemoteData.NotAsked
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
