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
        )
import Auth.Model exposing (CurrentUser)
import Browser exposing (UrlRequest(..))
import Engagements.Model exposing (Engagement)
import Meetings.Model exposing (Meeting)
import Quizzes.Model
    exposing
        ( Quiz
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
    | OnFetchAssignments (WebData (List Assignment))
    | OnFetchAssignmentGrades (WebData (List AssignmentGrade))
    | OnFetchTimeZone Time.Zone
    | OnFetchTimeZoneName Time.ZoneName
    | OnFetchAssignmentGradeDistributions (WebData (List AssignmentGradeDistribution))
    | OnBeginAssignment AssignmentSlug
    | OnFetchAssignmentSubmissions (WebData (List AssignmentSubmission))
    | OnBeginAssignmentComplete AssignmentSlug (WebData AssignmentSubmission)
    | OnFetchCurrentUser (WebData CurrentUser)
    | OnFetchQuizzes (WebData (List Quiz))
    | OnFetchQuizGrades (WebData (List QuizGrade))
    | OnFetchQuizGradeDistributions (WebData (List QuizGradeDistribution))
    | OnFetchQuizSubmissions (WebData (List QuizSubmission))
    | OnLocationChange BrowserLocation
    | LinkClicked UrlRequest
    | Tick Posix
    | OnSubmitAssignmentFieldSubmissions AssignmentSubmission
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
