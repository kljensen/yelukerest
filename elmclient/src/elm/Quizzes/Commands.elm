module Quizzes.Commands exposing
    ( createQuizSubmission
    , fetchQuizAnswers
    , fetchQuizGradeDistributions
    , fetchQuizGradeExceptions
    , fetchQuizGrades
    , fetchQuizQuestions
    , fetchQuizSubmissions
    , fetchQuizzes
    , submitQuizAnswers
    )

import Auth.Commands exposing (fetchForCurrentUser, handleJsonResponse, requestForJWT)
import Auth.Model exposing (CurrentUser, JWT, currentUserDecoder)
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( Quiz
        , QuizGrade
        , QuizGradeDistribution
        , QuizSubmission
        , quizAnswersDecoder
        , quizGradeDistributionsDecoder
        , quizGradeExceptionsDecoder
        , quizGradesDecoder
        , quizQuestionsDecoder
        , quizSubmissionDecoder
        , quizSubmissionsDecoder
        , quizzesDecoder
        )
import RemoteData exposing (WebData)
import String
import Task


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


fetchQuizAnswers : Int -> CurrentUser -> Cmd Msg
fetchQuizAnswers quizID currentUser =
    fetchForCurrentUser currentUser (fetchQuizAnswerUrl currentUser.id quizID) quizAnswersDecoder (Msgs.OnFetchQuizAnswers quizID)



-- fetchQuizAnswersForJWT : Int -> String -> Cmd Msg
-- fetchQuizAnswersForJWT quizID jwt =
--     fetchForJWT jwt (fetchQuizAnswerUrl currentUser.id quizID) quizAnswersDecoder (Msgs.OnFetchQuizAnswers quizID)


fetchQuizAnswerUrl : Int -> Int -> String
fetchQuizAnswerUrl userID quizID =
    "/rest/quiz_answers?user_id=eq." ++ String.fromInt userID ++ "&quiz_id=eq." ++ String.fromInt quizID


fetchQuizQuestionsUrl : Int -> String
fetchQuizQuestionsUrl quizID =
    "/rest/quiz_questions?select=id,body,options:quiz_question_options(id,body)&quiz_id=eq." ++ String.fromInt quizID


fetchQuizQuestions : Int -> CurrentUser -> Cmd Msg
fetchQuizQuestions quizID currentUser =
    fetchForCurrentUser currentUser (fetchQuizQuestionsUrl quizID) quizQuestionsDecoder (Msgs.OnFetchQuizQuestions quizID)


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



-- |> RemoteData.sendRequest
-- |> Cmd.map (Msgs.OnBeginQuizComplete quizID)


createQuizSubmission : CurrentUser -> Int -> Cmd Msg
createQuizSubmission user quizID =
    let
        jwt =
            user.jwt

        headers1 =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation"
            , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]

        insertResponseResolver =
            Http.stringResolver <| handleJsonResponse <| Decode.succeed quizID

        insertSubmissionRequest =
            Http.task
                { method = "POST"
                , headers = headers1
                , url = "/rest/quiz_submissions"
                , timeout = Nothing
                , resolver = insertResponseResolver
                , body = Http.jsonBody (Encode.object [ ( "quiz_id", Encode.int quizID ) ])
                }

        fetchResponseResolver =
            Http.stringResolver <| handleJsonResponse <| quizSubmissionsDecoder

        fetchSubmissionsRequest =
            Http.task
                { method = "GET"
                , headers = [ Http.header "Authorization" ("Bearer " ++ jwt) ]
                , url = fetchQuizSubmissionsUrl user.id
                , timeout = Nothing
                , resolver = fetchResponseResolver
                , body = Http.emptyBody
                }
    in
    insertSubmissionRequest
        |> Task.andThen (\x -> fetchSubmissionsRequest)
        |> Task.attempt RemoteData.fromResult
        |> Cmd.map (Msgs.OnBeginQuizComplete quizID)


submitQuizAnswers : CurrentUser -> Int -> List Int -> Cmd Msg
submitQuizAnswers currentUser quizID quizQuestionOptionIds =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ currentUser.jwt)
            , Http.header "Prefer" "return=representation"
            ]

        saveRequest =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/rpc/save_quiz"
                , timeout = Nothing
                , expect = Http.expectJson (RemoteData.fromResult >> Msgs.OnSubmitQuizAnswersComplete quizID) quizAnswersDecoder
                , tracker = Nothing
                , body =
                    Http.jsonBody
                        (Encode.object
                            [ ( "quiz_id", Encode.int quizID )
                            , ( "quiz_question_option_ids"
                              , quizQuestionOptionIds
                                    |> Encode.list Encode.int
                              )
                            ]
                        )
                }
    in
    saveRequest
