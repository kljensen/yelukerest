module Msgs exposing (BrowserLocation(..), Msg(..))

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentFieldSubmission
        , AssignmentGrade
        , AssignmentGradeDistribution
        , AssignmentGradeException
        , AssignmentSlug
        , AssignmentSubmission
        , RepositoryError
        , RepositoryStatus
        )
import Auth.Model exposing (CurrentUser)
import Browser exposing (UrlRequest(..))
import ApiTokens.Model exposing (ApiToken, CreatedToken)
import ConnectedApps.Model exposing (ConnectedApps)
import DataGrants.Model exposing (ApiGrant, CreatedGrant)
import Http
import Engagements.Model exposing (Engagement)
import Meetings.Model exposing (Meeting)
import Quizzes.Model
    exposing
        ( Quiz
        , QuizArtifact
        , QuizGrade
        , QuizGradeDistribution
        , QuizSubmission
        )
import RemoteData exposing (WebData)
import Time exposing (Posix)
import Url exposing (Url)
import Users.Model exposing (User, UserSecret)


type BrowserLocation
    = StringLocation String
    | UrlLocation Url


type Msg
    = OnFetchMeetings (WebData (List Meeting))
    | OnFetchConnectedApps (WebData ConnectedApps)
    | OnFetchApiTokens (WebData (List ApiToken))
    | OnCreateApiToken (WebData CreatedToken)
    | OnRevokeApiToken Int (WebData ())
    | CreateApiToken
    | RevokeApiToken Int
    | SetApiTokenDraftName String
    | SetApiTokenDraftScope String Bool
    | DismissCreatedApiToken
    | OnFetchDataGrants (WebData (List ApiGrant))
    | OnCreateDataGrant (Result String CreatedGrant)
    | OnRevokeDataGrant Int (WebData ())
    | CreateDataGrant
    | RevokeDataGrant Int
    | SetDataGrantDraftName String
    | SetDataGrantDraftExpiry String
    | AddDataGrantDraftAssignment
    | RemoveDataGrantDraftAssignment Int
    | SetDataGrantDraftAssignmentSlug Int String
    | SetDataGrantDraftIdentity Int String Bool
    | SetDataGrantDraftField Int String Bool
    | DismissCreatedDataGrant
    | DisconnectApp String String
    | OnDisconnectApp String (Result Http.Error ())
    | OnFetchAssignments (WebData (List Assignment))
    | OnFetchAssignmentGrades (WebData (List AssignmentGrade))
    | OnFetchTimeZone Time.Zone
    | OnFetchTimeZoneName Time.ZoneName
    | OnFetchAssignmentGradeDistributions (WebData (List AssignmentGradeDistribution))
    | OnBeginAssignment AssignmentSlug
    | OnFetchAssignmentSubmissions (WebData (List AssignmentSubmission))
    | OnBeginAssignmentComplete AssignmentSlug (WebData AssignmentSubmission)
      -- Self-serve assignment repositories (issue #397). The responses carry
      -- the request number they answer (see
      -- Assignments.Model.RepositoryGenerations) and the time they arrived,
      -- so the poll window and any Retry-After hold are measured from a real
      -- clock rather than the five-second Tick.
    | OnCreateRepository AssignmentSlug
    | OnCreateRepositoryResponse AssignmentSlug Int Posix (Result RepositoryError RepositoryStatus)
    | OnLoadRepository AssignmentSlug
    | OnLoadRepositoryResponse AssignmentSlug Int Posix (Result RepositoryError RepositoryStatus)
    | OnRepositoryPollTick Posix
    | OnFetchCurrentUser (WebData CurrentUser)
    | OnFetchQuizzes (WebData (List Quiz))
    | OnFetchQuizArtifacts (WebData (List QuizArtifact))
    | OnFetchQuizGrades (WebData (List QuizGrade))
    | OnFetchQuizGradeDistributions (WebData (List QuizGradeDistribution))
    | OnFetchQuizSubmissions (WebData (List QuizSubmission))
    | OnLocationChange BrowserLocation
    | LinkClicked UrlRequest
    | Tick Posix
    | OnSubmitAssignmentFieldSubmissions AssignmentSubmission
      -- Submit on a template assignment nobody has begun: the submission
      -- row is created and the answers sent as one action (issue #397).
    | OnBeginAndSubmitAssignmentFieldSubmissions AssignmentSlug
    | OnSubmitAssignmentFieldSubmissionsResponse AssignmentSlug (WebData (List AssignmentFieldSubmission))
    | OnUpdateAssignmentFieldSubmissionInput Int String String
    | OnFetchEngagements (WebData (List Engagement))
    | OnFetchUsers (WebData (List User))
    | OnFetchUserSecrets (WebData (List UserSecret))
    | OnChangeEngagement String Int String
    | OnSubmitEngagementResponse String Int (WebData Engagement)
    | OnFetchAssignmentGradeExceptions (WebData (List AssignmentGradeException))
    | ToggleShowUserSecret String
    | OnChangeEngagementUserQuery String
