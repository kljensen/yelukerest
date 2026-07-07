module Models exposing (Flags, Model, Route(..), TimeZone, UIElements, initialModel)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentFieldSubmissionInputs
        , AssignmentGrade
        , AssignmentGradeDistribution
        , AssignmentGradeException
        , AssignmentSlug
        , AssignmentSubmission
        , PendingAssignmentFieldSubmissionRequests
        , PendingBeginAssignments
        )
import Auth.Model exposing (CurrentUser)
import Browser.Navigation exposing (Key)
import Dict exposing (Dict)
import Engagements.Model exposing (Engagement)
import Meetings.Model exposing (Meeting, MeetingSlug)
import Quizzes.Model
    exposing
        ( Quiz
        , QuizArtifact
        , QuizGrade
        , QuizGradeDistribution
        , QuizSubmission
        )
import RemoteData exposing (WebData)
import Set exposing (Set)
import Time exposing (Posix, Zone, ZoneName(..), utc)
import Users.Model exposing (User, UserSecret)


type alias Flags =
    { courseTitle : String
    , piazzaURL : Maybe String
    , aboutURL : String
    , canvasURL : String
    , slackURL : Maybe String
    , location : String
    }


type alias UIElements =
    { courseTitle : String
    , piazzaURL : Maybe String
    , aboutURL : String
    , canvasURL : String
    , slackURL : Maybe String
    }


type alias TimeZone =
    { zone : Zone
    , zoneName : ZoneName
    }


type alias Model =
    { current_date : Maybe Posix
    , timeZone : TimeZone
    , route : Route
    , navKey : Key
    , meetings : WebData (List Meeting)
    , currentUser : WebData CurrentUser
    , userSecrets : WebData (List UserSecret)
    , userSecretsToShow : Set String
    , assignments : WebData (List Assignment)
    , quizzes : WebData (List Quiz)
    , quizSubmissions : WebData (List QuizSubmission)
    , quizArtifacts : WebData (List QuizArtifact)
    , quizGrades : WebData (List QuizGrade)
    , quizGradeDistributions : WebData (List QuizGradeDistribution)
    , uiElements : UIElements
    , assignmentGradeExceptions : WebData (List AssignmentGradeException)
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

    , engagements : WebData (List Engagement)
    , users : WebData (List User)
    , pendingSubmitEngagements : Dict ( String, Int ) (WebData Engagement)
    , engagementUserQuery : Maybe String
    }


initialModel : Flags -> Route -> Key -> Model
initialModel flags route key =
    { current_date = Nothing
    , timeZone = { zone = utc, zoneName = Name "utc" }
    , route = route
    , navKey = key
    , meetings = RemoteData.Loading
    , currentUser = RemoteData.Loading
    , userSecrets = RemoteData.NotAsked
    , userSecretsToShow = Set.empty
    , assignments = RemoteData.NotAsked
    , quizzes = RemoteData.NotAsked
    , quizSubmissions = RemoteData.NotAsked
    , quizArtifacts = RemoteData.NotAsked
    , quizGrades = RemoteData.NotAsked
    , quizGradeDistributions = RemoteData.NotAsked
    , uiElements =
        { courseTitle = flags.courseTitle
        , piazzaURL = flags.piazzaURL
        , aboutURL = flags.aboutURL
        , canvasURL = flags.canvasURL
        , slackURL = flags.slackURL
        }
    , assignmentGradeExceptions = RemoteData.NotAsked
    , assignmentSubmissions = RemoteData.NotAsked
    , assignmentGrades = RemoteData.NotAsked
    , assignmentGradeDistributions = RemoteData.NotAsked
    , pendingBeginAssignments = Dict.empty
    , assignmentFieldSubmissionInputs = Dict.empty
    , pendingAssignmentFieldSubmissionRequests = Dict.empty
    , engagements = RemoteData.NotAsked
    , users = RemoteData.NotAsked
    , pendingSubmitEngagements = Dict.empty
    , engagementUserQuery = Nothing
    }


type Route
    = IndexRoute
    | CurrentUserDashboardRoute
    | MeetingListRoute
    | MeetingDetailRoute MeetingSlug
    | AssignmentListRoute
    | AssignmentDetailRoute AssignmentSlug
    | AssignmentGradeDetailRoute AssignmentSlug
    | EditEngagementsRoute String
    | NotFoundRoute
