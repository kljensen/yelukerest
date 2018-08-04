module Quizzes.Commands exposing (fetchQuizSubmissions, fetchQuizzes)

import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)
import Msgs exposing (Msg)
import Quizzes.Model exposing (Quiz, QuizSubmission, quizSubmissionDecoder, quizSubmissionsDecoder, quizzesDecoder)


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
    "/rest/quiz_submissions?user_id=eq." ++ toString userID


fetchQuizAnswers : CurrentUser -> Cmd Msg
fetchQuizAnswers currentUser =
    fetchForCurrentUser currentUser (fetchQuizAnswerUrl currentUser.id) quizSubmissionsDecoder Msgs.OnFetchQuizSubmissions


fetchQuizAnswerUrl : Int -> String
fetchQuizAnswerUrl userID =
    "/rest/quiz_answers?user_id=eq." ++ toString userID
