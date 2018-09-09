module Quizzes.Updates
    exposing
        ( onBeginQuiz
        , onBeginQuizComplete
        , onFetchQuizGradeDistributions
        , onFetchQuizGrades
        , onFetchQuizSubmissions
        , onSubmitQuizAnswers
        , onSubmitQuizAnswersComplete
        , takeQuiz
        )

import Dict
import Models exposing (Model)
import Msgs exposing (Msg)
import Navigation exposing (load)
import Quizzes.Commands
    exposing
        ( createQuizSubmission
        , fetchQuizAnswers
        , fetchQuizQuestions
        , fetchQuizSubmissions
        , fetchQuizzes
        , submitQuizAnswers
        )
import Quizzes.Model
    exposing
        ( QuizAnswer
        , QuizGrade
        , QuizGradeDistribution
        , QuizSubmission
        )
import RemoteData exposing (WebData)
import Set


onSubmitQuizAnswers : Model -> Int -> List Int -> ( Model, Cmd Msg )
onSubmitQuizAnswers model quizID quizQuestionOptionIds =
    -- We have to get a list of all the quiz answer inputs
    -- that are currently toggled. Then we'll submit them
    -- to the server and set some 'pending' state.
    let
        cmds =
            case model.currentUser of
                RemoteData.Success user ->
                    let
                        selectedOptionIds =
                            model.quizQuestionOptionInputs
                                |> Set.intersect (Set.fromList quizQuestionOptionIds)
                                |> Set.toList
                    in
                    submitQuizAnswers user quizID selectedOptionIds

                _ ->
                    Cmd.none

        newModel =
            case model.currentUser of
                RemoteData.Success user ->
                    { model | pendingSubmitQuizzes = Dict.insert quizID RemoteData.Loading model.pendingSubmitQuizzes }

                _ ->
                    model
    in
    ( newModel, Cmd.batch [ cmds ] )


onSubmitQuizAnswersComplete : Model -> Int -> WebData (List QuizAnswer) -> ( Model, Cmd Msg )
onSubmitQuizAnswersComplete model quizID response =
    let
        psqs =
            case response of
                RemoteData.Success quizAnswers ->
                    Dict.remove quizID model.pendingSubmitQuizzes

                _ ->
                    Dict.insert quizID response model.pendingSubmitQuizzes
    in
    -- Update the pending submit quizzes and the quiz answers, which
    -- we just received back in the response. (See the save_quiz RPC.)
    ( { model
        | pendingSubmitQuizzes = psqs
        , quizAnswers = Dict.insert quizID response model.quizAnswers
      }
    , Cmd.none
    )


onFetchQuizSubmissions : Model -> WebData (List QuizSubmission) -> ( Model, Cmd Msg )
onFetchQuizSubmissions model response =
    ( { model | quizSubmissions = response }, Cmd.none )


onBeginQuizComplete : Model -> Int -> WebData (List QuizSubmission) -> ( Model, Cmd Msg )
onBeginQuizComplete model quizID response =
    let
        ( newPBQs, newQuizSubmissions ) =
            case response of
                RemoteData.Success _ ->
                    ( Dict.remove quizID model.pendingBeginQuizzes, response )

                x ->
                    ( Dict.insert quizID x model.pendingBeginQuizzes, model.quizSubmissions )

        newModel =
            { model | pendingBeginQuizzes = newPBQs, quizSubmissions = newQuizSubmissions }
    in
    takeQuiz newModel quizID


onBeginQuiz : Model -> Int -> ( Model, Cmd Msg )
onBeginQuiz model quizID =
    let
        newModel =
            { model | pendingBeginQuizzes = Dict.insert quizID RemoteData.Loading model.pendingBeginQuizzes }

        cmds =
            case model.currentUser of
                RemoteData.Success user ->
                    Cmd.batch [ createQuizSubmission user.jwt quizID ]

                _ ->
                    Cmd.none
    in
    -- todo, POST to create quiz submission. Add to pendingBeginQuizzes,
    -- show that status as greyed-out button. After that
    -- succeeds, redirect to page or failure
    ( newModel, cmds )


takeQuiz : Model -> Int -> ( Model, Cmd Msg )
takeQuiz model quizID =
    let
        extraCmds =
            case model.currentUser of
                RemoteData.Success user ->
                    [ fetchQuizQuestions quizID user
                    , fetchQuizAnswers quizID user
                    ]

                _ ->
                    []

        newModel =
            { model
                | quizQuestions = Dict.insert quizID RemoteData.Loading model.quizQuestions
                , quizAnswers = Dict.insert quizID RemoteData.Loading model.quizAnswers
            }
    in
    ( newModel, Cmd.batch ([ load ("#quiz-submissions/" ++ toString quizID) ] ++ extraCmds) )


onFetchQuizGrades : Model -> WebData (List QuizGrade) -> ( Model, Cmd Msg )
onFetchQuizGrades model response =
    ( { model | quizGrades = response }, Cmd.none )


onFetchQuizGradeDistributions : Model -> WebData (List QuizGradeDistribution) -> ( Model, Cmd Msg )
onFetchQuizGradeDistributions model response =
    ( { model | quizGradeDistributions = response }, Cmd.none )
