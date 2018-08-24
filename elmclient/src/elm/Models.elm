module Models exposing (..)

import Assignments.Model exposing (Assignment, AssignmentFieldSubmissionInputs, AssignmentSlug, AssignmentSubmission, PendingAssignmentFieldSubmissionRequests, PendingBeginAssignments)
import Auth.Model exposing (CurrentUser)
import Date exposing (Date)
import Dict exposing (Dict)
import Engagements.Model exposing (Engagement)
import Meetings.Model exposing (Meeting, MeetingSlug)
import Msgs exposing (Msg, SSEMsg(..))
import Quizzes.Model exposing (Quiz, QuizAnswer, QuizQuestion, QuizSubmission)
import RemoteData exposing (WebData)
import SSE exposing (SseAccess)
import Set exposing (Set)
import Users.Model exposing (User)


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
    , quizSubmissions : WebData (List QuizSubmission)
    , uiElements : UIElements
    , assignmentSubmissions : WebData (List AssignmentSubmission)

    -- A dictionary that tracks requests initiated to begin a
    -- particular assignment, that is, to create an assignment submission
    -- for the current user.
    , pendingBeginAssignments : PendingBeginAssignments

    -- A dictionary tracking the current value of <input> elements
    -- that the user has edited for particular assignment field submissions.
    , assignmentFieldSubmissionInputs : AssignmentFieldSubmissionInputs

    -- A dictionary tracking POST requests to the server to save
    -- assigment field submissions.
    , pendingAssignmentFieldSubmissionRequests : PendingAssignmentFieldSubmissionRequests

    -- A dictionary tracking POST requests to the server to create
    -- new quiz submissions.
    , pendingBeginQuizzes : Dict Int (WebData (List QuizSubmission))
    , pendingSubmitQuizzes : Dict Int (WebData (List QuizAnswer))
    , quizAnswers : Dict Int (WebData (List QuizAnswer))
    , quizQuestions : Dict Int (WebData (List QuizQuestion))
    , quizQuestionOptionInputs : Set Int
    , sse : SseAccess Msgs.Msg
    , latestMessage : Result String String
    , engagements : WebData (List Engagement)
    , users : WebData (List User)
    , pendingSubmitEngagements : Dict ( Int, Int ) (WebData Engagement)
    }


initialModel : Flags -> Route -> Model
initialModel flags route =
    { current_date = Nothing
    , route = route
    , meetings = RemoteData.Loading
    , currentUser = RemoteData.Loading
    , assignments = RemoteData.NotAsked
    , quizzes = RemoteData.NotAsked
    , quizSubmissions = RemoteData.NotAsked
    , uiElements =
        { courseTitle = flags.courseTitle
        , piazzaURL = flags.piazzaURL
        }
    , assignmentSubmissions = RemoteData.NotAsked
    , pendingBeginAssignments = Dict.empty
    , pendingBeginQuizzes = Dict.empty
    , pendingSubmitQuizzes = Dict.empty
    , assignmentFieldSubmissionInputs = Dict.empty
    , pendingAssignmentFieldSubmissionRequests = Dict.empty
    , quizAnswers = Dict.empty
    , quizQuestions = Dict.empty
    , quizQuestionOptionInputs = Set.empty
    , sse = SSE.create "/events/events/" (Msgs.OnSSE Msgs.Noop)
    , latestMessage = Ok "nothing"
    , engagements = RemoteData.NotAsked
    , users = RemoteData.NotAsked
    , pendingSubmitEngagements = Dict.empty
    }


type Route
    = IndexRoute
    | CurrentUserDashboardRoute
    | MeetingListRoute
    | MeetingDetailRoute MeetingSlug
    | AssignmentListRoute
    | AssignmentDetailRoute AssignmentSlug
    | EditEngagementsRoute Int
    | TakeQuizRoute Int
    | NotFoundRoute
