module Msgs exposing (..)

import Assignments.Model exposing (Assignment, AssignmentFieldSubmission, AssignmentSlug, AssignmentSubmission)
import Auth.Model exposing (CurrentUser)
import Meetings.Model exposing (Meeting)
import Navigation exposing (Location)
import Quizzes.Model exposing (Quiz, QuizAnswer, QuizQuestion, QuizSubmission)
import RemoteData exposing (WebData)
import Time exposing (Time)


type Msg
    = OnFetchMeetings (WebData (List Meeting))
    | OnFetchAssignments (WebData (List Assignment))
    | OnBeginAssignment AssignmentSlug
    | OnFetchAssignmentSubmissions (WebData (List AssignmentSubmission))
    | OnBeginAssignmentComplete AssignmentSlug (WebData AssignmentSubmission)
    | OnFetchCurrentUser (WebData CurrentUser)
    | OnFetchQuizzes (WebData (List Quiz))
    | OnFetchQuizSubmissions (WebData (List QuizSubmission))
    | OnLocationChange Location
    | Tick Time
    | OnSubmitAssignmentFieldSubmissions Assignment
    | OnSubmitAssignmentFieldSubmissionsResponse AssignmentSlug (WebData (List AssignmentFieldSubmission))
    | OnUpdateAssignmentFieldSubmissionInput Int String
    | OnBeginQuiz Int
    | OnBeginQuizComplete Int (WebData QuizSubmission)
    | OnFetchQuizQuestions Int (WebData (List QuizQuestion))
    | TakeQuiz Int
    | OnFetchQuizAnswers Int (WebData (List QuizAnswer))
    | OnSubmitQuizAnswers Int (List Int)
    | OnSubmitQuizAnswersComplete Int (WebData (List QuizAnswer))
    | OnToggleQuizQuestionOption Int Bool
