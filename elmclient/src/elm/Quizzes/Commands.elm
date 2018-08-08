module Quizzes.Commands
    exposing
        ( createQuizSubmission
        , fetchQuizAnswers
        , fetchQuizQuestions
        , fetchQuizSubmissions
        , fetchQuizzes
        , submitQuizAnswers
        )

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


fetchQuizAnswers : Int -> CurrentUser -> Cmd Msg
fetchQuizAnswers quizID currentUser =
    fetchForCurrentUser currentUser (fetchQuizAnswerUrl currentUser.id quizID) quizAnswersDecoder (Msgs.OnFetchQuizAnswers quizID)


fetchQuizAnswerUrl : Int -> Int -> String
fetchQuizAnswerUrl userID quizID =
    "/rest/quiz_answers?user_id=eq." ++ toString userID ++ "&quiz_id=eq." ++ toString quizID


fetchQuizQuestionsUrl : Int -> String
fetchQuizQuestionsUrl quizID =
    "/rest/quiz_questions?select=id,body,options:quiz_question_options(id,body)&quiz_id=eq." ++ toString quizID


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


submitQuizAnswers : JWT -> Int -> List Int -> Cmd Msg
submitQuizAnswers jwt quizID quizQuestionOptionIds =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation"
            ]

        request =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/rpc/save_quiz"
                , timeout = Nothing
                , expect = Http.expectJson quizAnswersDecoder
                , withCredentials = False
                , body =
                    Http.jsonBody
                        (Encode.object
                            [ ( "quiz_id", Encode.int quizID )
                            , ( "quiz_question_option_ids"
                              , quizQuestionOptionIds
                                    |> List.map Encode.int
                                    |> Encode.list
                              )
                            ]
                        )
                }
    in
    request
        |> RemoteData.sendRequest
        |> Cmd.map (Msgs.OnSubmitQuizAnswersComplete quizID)
