module Quizzes.Commands exposing (fetchQuizzes)

import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)
import Msgs exposing (Msg)
import Quizzes.Model exposing (Quiz, QuizSubmission, quizSubmissionDecoder, quizzesDecoder)
import RemoteData exposing (WebData)


fetchQuizzes : WebData CurrentUser -> Cmd Msg
fetchQuizzes currentUser =
    fetchForCurrentUser currentUser fetchQuizzesUrl quizzesDecoder Msgs.OnFetchQuizzes


fetchQuizzesUrl : String
fetchQuizzesUrl =
    "/rest/quizzes?order=closed_at"
