module Quizzes.Commands exposing
    ( fetchQuizGradeDistributions
    , fetchQuizGradeExceptions
    , fetchQuizGrades
    , fetchQuizSubmissions
    , fetchQuizzes
    )

import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( quizGradeDistributionsDecoder
        , quizGradeExceptionsDecoder
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


fetchQuizGradeExceptions : CurrentUser -> Cmd Msg
fetchQuizGradeExceptions currentUser =
    fetchForCurrentUser currentUser fetchQuizGradeExceptionsUrl quizGradeExceptionsDecoder Msgs.OnFetchQuizGradeExceptions


fetchQuizGradeExceptionsUrl : String
fetchQuizGradeExceptionsUrl =
    "/rest/quiz_grade_exceptions"
