module Models exposing (Flags, Model, Route(..), UIElements, initialModel)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentFieldSubmissionInputs
        , AssignmentGrade
        , AssignmentGradeDistribution
        , AssignmentSlug
        , AssignmentSubmission
        , PendingAssignmentFieldSubmissionRequests
        , PendingBeginAssignments
        )
import Auth.Model exposing (CurrentUser)
import Dict exposing (Dict)
import Engagements.Model exposing (Engagement)
import Json.Decode
import Meetings.Model exposing (Meeting, MeetingSlug)
import Msgs exposing (Msg, SSEMsg(..))
import Quizzes.Model
    exposing
        ( Quiz
        , QuizAnswer
        , QuizGrade
        , QuizGradeDistribution
        , QuizQuestion
        , QuizSubmission
        )
import RemoteData exposing (WebData)
import SSE exposing (SseAccess)
import Set exposing (Set)
import Time exposing (Posix)
import Users.Model exposing (User)


type alias Flags =
    { courseTitle : String
    , piazzaURL : Maybe String
    , aboutURL : String
    , canvasURL : String
    , location : String
    }


type alias UIElements =
    { courseTitle : String
    , piazzaURL : Maybe String
    , aboutURL : String
    , canvasURL : String
    }


type alias Model =
    { current_date : Maybe Posix
    , route : Route
    , meetings : WebData (List Meeting)
    , currentUser : WebData CurrentUser
    , assignments : WebData (List Assignment)
    , quizzes : WebData (List Quiz)
    , quizSubmissions : WebData (List QuizSubmission)
    , quizGrades : WebData (List QuizGrade)
    , quizGradeDistributions : WebData (List QuizGradeDistribution)
    , uiElements : UIElements
    , assignmentSubmissions : WebData (List AssignmentSubmission)
    , assignmentGrades : WebData (List AssignmentGrade)
    , assignmentGradeDistributions : WebData (List AssignmentGradeDistribution)

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
    , latestMessage : Result Json.Decode.Error String
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
    , quizGrades = RemoteData.NotAsked
    , quizGradeDistributions = RemoteData.NotAsked
    , uiElements =
        { courseTitle = flags.courseTitle
        , piazzaURL = flags.piazzaURL
        , aboutURL = flags.aboutURL
        , canvasURL = flags.canvasURL
        }
    , assignmentSubmissions = RemoteData.NotAsked
    , assignmentGrades = RemoteData.NotAsked
    , assignmentGradeDistributions = RemoteData.NotAsked
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
