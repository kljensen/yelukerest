module Quizzes.Commands exposing (createQuizSubmission, fetchQuizAnswers, fetchQuizQuestions, fetchQuizSubmissions, fetchQuizzes)

import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser, JWT, currentUserDecoder)
import Http
import Json.Encode as Encode
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( Quiz
        , QuizSubmission
        , quizAnswersDecoder
        , quizQuestionsDecoder
        , quizSubmissionDecoder
        , quizSubmissionsDecoder
        , quizzesDecoder
        )
import RemoteData exposing (WebData)


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
    fetchForCurrentUser currentUser (fetchQuizAnswerUrl currentUser.id) quizAnswersDecoder Msgs.OnFetchQuizAnswers


fetchQuizAnswerUrl : Int -> String
fetchQuizAnswerUrl userID =
    "/rest/quiz_answers?user_id=eq." ++ toString userID


fetchQuizQuestionsUrl : Int -> String
fetchQuizQuestionsUrl quizID =
    "/rest/quiz_questions?select=id,body,quiz_question_options(id,body)&quiz_id=eq." ++ toString quizID


fetchQuizQuestions : Int -> CurrentUser -> Cmd Msg
fetchQuizQuestions quizID currentUser =
    fetchForCurrentUser currentUser (fetchQuizQuestionsUrl quizID) quizQuestionsDecoder (Msgs.OnFetchQuizQuestions quizID)


createQuizSubmission : JWT -> Int -> Cmd Msg
createQuizSubmission jwt quizID =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation"
            , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]

        request =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/quiz_submissions"
                , timeout = Nothing
                , expect = Http.expectJson quizSubmissionDecoder
                , withCredentials = False
                , body = Http.jsonBody (Encode.object [ ( "quiz_id", Encode.int quizID ) ])
                }
    in
    request
        |> RemoteData.sendRequest
        |> Cmd.map (Msgs.OnBeginQuizComplete quizID)
