module Quizzes.Commands exposing
    ( fetchQuizArtifacts
    , fetchQuizGradeDistributions
    , fetchQuizGrades
    , fetchQuizSubmissions
    , fetchQuizzes
    )

import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( quizArtifactsDecoder
        , quizGradeDistributionsDecoder
        , quizGradesDecoder
        , quizSubmissionsDecoder
        , quizzesDecoder
        )
import String


fetchQuizzes : CurrentUser -> Cmd Msg
fetchQuizzes currentUser =
    fetchForCurrentUser currentUser fetchQuizzesUrl quizzesDecoder Msgs.OnFetchQuizzes


fetchQuizzesUrl : String
fetchQuizzesUrl =
    "/rest/quizzes?order=closed_at"


fetchQuizSubmissions : CurrentUser -> Cmd Msg
fetchQuizSubmissions currentUser =
    fetchForCurrentUser currentUser (fetchQuizSubmissionsUrl currentUser.id) quizSubmissionsDecoder Msgs.OnFetchQuizSubmissions


fetchQuizSubmissionsUrl : Int -> String
fetchQuizSubmissionsUrl userID =
    "/rest/quiz_submissions_info?user_id=eq." ++ String.fromInt userID


fetchQuizArtifacts : CurrentUser -> Cmd Msg
fetchQuizArtifacts currentUser =
    fetchForCurrentUser currentUser (fetchQuizArtifactsUrl currentUser.id) quizArtifactsDecoder Msgs.OnFetchQuizArtifacts


fetchQuizArtifactsUrl : Int -> String
fetchQuizArtifactsUrl userID =
    "/rest/artifacts?user_id=eq." ++ String.fromInt userID ++ "&quiz_id=not.is.null&order=quiz_id,slug"


fetchQuizGrades : CurrentUser -> Cmd Msg
fetchQuizGrades currentUser =
    fetchForCurrentUser currentUser (fetchQuizGradesUrl currentUser.id) quizGradesDecoder Msgs.OnFetchQuizGrades


fetchQuizGradesUrl : Int -> String
fetchQuizGradesUrl userID =
    "/rest/quiz_grades?user_id=eq." ++ String.fromInt userID


fetchQuizGradeDistributions : CurrentUser -> Cmd Msg
fetchQuizGradeDistributions currentUser =
    fetchForCurrentUser currentUser fetchQuizGradeDistributionsUrl quizGradeDistributionsDecoder Msgs.OnFetchQuizGradeDistributions


fetchQuizGradeDistributionsUrl : String
fetchQuizGradeDistributionsUrl =
    "/rest/quiz_grade_distributions"
