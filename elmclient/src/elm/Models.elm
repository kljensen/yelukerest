module Models exposing (..)

import Assignments.Model exposing (Assignment, AssignmentSlug, AssignmentSubmission, PendingBeginAssignments)
import Auth.Model exposing (CurrentUser)
import Date exposing (Date)
import Dict exposing (Dict)
import Meetings.Model exposing (Meeting, MeetingSlug)
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
    , route : Route
    , meetings : WebData (List Meeting)
    , currentUser : WebData CurrentUser
    , assignments : WebData (List Assignment)
    , quizzes : WebData (List Quiz)
    , uiElements : UIElements
    , assignmentSubmissions : WebData (List AssignmentSubmission)

    -- A dictionary that tracks requests initiated to begin a
    -- particular assignment, that is, to create an assignment submission
    -- for the current user.
    , pendingBeginAssignments : PendingBeginAssignments
    }


initialModel : Flags -> Route -> Model
initialModel flags route =
    { current_date = Nothing
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
    , pendingBeginAssignments = Dict.empty
    }


type Route
    = IndexRoute
    | CurrentUserDashboardRoute
    | MeetingListRoute
    | MeetingDetailRoute MeetingSlug
    | AssignmentListRoute
    | AssignmentDetailRoute AssignmentSlug
    | NotFoundRoute
