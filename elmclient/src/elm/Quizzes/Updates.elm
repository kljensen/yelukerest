module Quizzes.Updates
    exposing
        ( onSubmitQuizAnswers
        , onSubmitQuizAnswersComplete
        )

import Dict
import Models exposing (Model)
import Msgs exposing (Msg)
import Quizzes.Commands exposing (submitQuizAnswers)
import Quizzes.Model exposing (QuizAnswer)
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
                    submitQuizAnswers user.jwt quizID selectedOptionIds

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
        newModel =
            case response of
                RemoteData.Success quizAnswers ->
                    { model | pendingSubmitQuizzes = Dict.remove quizID model.pendingSubmitQuizzes }

                _ ->
                    { model | pendingSubmitQuizzes = Dict.insert quizID response model.pendingSubmitQuizzes }
    in
    ( newModel, Cmd.none )
