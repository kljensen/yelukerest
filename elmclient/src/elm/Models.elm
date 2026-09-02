module Models exposing (Flags, Model, Route(..), TimeZone, UIElements, initialModel, mcpEndpoint)

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
import ApiTokens.Model exposing (ApiToken, CreatedToken, defaultScopes)
import ConnectedApps.Model exposing (ConnectedApps)
import Dict exposing (Dict)
import Engagements.Model exposing (Engagement, PendingSubmit)
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
import Url exposing (Url)
import Users.Model exposing (User, UserSecret)


type alias Flags =
    { courseTitle : String
    , piazzaURL : Maybe String
    , aboutURL : String
    , canvasURL : String
    , slackURL : Maybe String
    }


type alias UIElements =
    { courseTitle : String
    , piazzaURL : Maybe String
    , aboutURL : String
    , canvasURL : String
    , slackURL : Maybe String

    -- Where an AI assistant connects, built from the origin the browser is
    -- already on rather than configured, so the #/mcp page can never show a
    -- placeholder or a stale host.
    , mcpEndpoint : String
    }


{-| The course MCP endpoint for the origin of `url`.

Only the scheme, host and port are kept: the URL this is derived from is the
one the browser is on, fragment and all, and `#/mcp` is not part of an
address anybody should type.

-}
mcpEndpoint : Url -> String
mcpEndpoint url =
    let
        scheme =
            case url.protocol of
                Url.Https ->
                    "https://"

                Url.Http ->
                    "http://"

        port_ =
            case url.port_ of
                Just p ->
                    ":" ++ String.fromInt p

                Nothing ->
                    ""
    in
    scheme ++ url.host ++ port_ ++ "/mcp"


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

    -- Applications the student has authorized to reach their course data,
    -- and the client ids whose disconnect is currently in flight.
    , connectedApps : WebData ConnectedApps
    , pendingDisconnects : Set String

    -- Personal access tokens (issue #318), the draft form beside them, and the
    -- one-time secret from the most recent create. `justCreatedApiToken` is
    -- deliberately transient state: it is the only place the secret exists
    -- outside the database and it must not survive a navigation.
    , apiTokens : WebData (List ApiToken)
    , justCreatedApiToken : Maybe CreatedToken
    , apiTokenDraftName : String
    , apiTokenDraftScopes : Set String
    , pendingApiTokenRevokes : Set Int

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
    , pendingSubmitEngagements : Dict ( String, Int ) PendingSubmit
    , engagementUserQuery : Maybe String
    }


initialModel : Flags -> Url -> Route -> Key -> Model
initialModel flags url route key =
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
        , mcpEndpoint = mcpEndpoint url
        }
    , assignmentGradeExceptions = RemoteData.NotAsked
    , assignmentSubmissions = RemoteData.NotAsked
    , assignmentGrades = RemoteData.NotAsked
    , assignmentGradeDistributions = RemoteData.NotAsked
    , connectedApps = RemoteData.NotAsked
    , pendingDisconnects = Set.empty
    , apiTokens = RemoteData.NotAsked
    , justCreatedApiToken = Nothing
    , apiTokenDraftName = ""
    , apiTokenDraftScopes = Set.fromList defaultScopes
    , pendingApiTokenRevokes = Set.empty
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
    | ConnectedAppsRoute
    | ApiTokensRoute
    | McpRoute
    | NotFoundRoute
