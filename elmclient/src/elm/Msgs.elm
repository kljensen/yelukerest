module Msgs exposing (BrowserLocation(..), Msg(..), SSEMsg(..))

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
import Json.Decode
import Meetings.Model exposing (Meeting)
import Quizzes.Model
    exposing
        ( Quiz
        , QuizAnswer
        , QuizGrade
        , QuizGradeDistribution
        , QuizGradeException
        , QuizQuestion
        , QuizSubmission
        )
import RemoteData exposing (WebData)
import Time exposing (Posix)
import Url exposing (Url)
import Users.Model exposing (User, UserSecret)


type BrowserLocation
    = StringLocation String
    | UrlLocation Url


type SSEMsg
    = Noop
    | SSETableChange (Result Json.Decode.Error String)


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
    | OnBeginQuiz Int
    | OnBeginQuizComplete Int (WebData (List QuizSubmission))
    | OnFetchQuizQuestions Int (WebData (List QuizQuestion))
    | TakeQuiz Int
    | OnFetchQuizAnswers Int (WebData (List QuizAnswer))
    | OnSubmitQuizAnswers Int (List Int)
    | OnSubmitQuizAnswersComplete Int (WebData (List QuizAnswer))
    | OnToggleQuizQuestionOption Int Bool
    | OnSSE SSEMsg
    | OnFetchEngagements (WebData (List Engagement))
    | OnFetchUsers (WebData (List User))
    | OnFetchUserSecrets (WebData (List UserSecret))
    | OnChangeEngagement String Int String
    | OnSubmitEngagementResponse String Int (WebData Engagement)
    | OnFetchQuizGradeExceptions (WebData (List QuizGradeException))
    | OnFetchAssignmentGradeExceptions (WebData (List AssignmentGradeException))
    | ToggleShowUserSecret String
