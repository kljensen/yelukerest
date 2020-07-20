module Quizzes.Updates exposing
    ( onBeginQuiz
    , onBeginQuizComplete
    , onFetchQuizGradeDistributions
    , onFetchQuizGrades
    , onFetchQuizAnswers
    , onFetchQuizSubmissions
    , onSubmitQuizAnswers
    , onSubmitQuizAnswersComplete
    , takeQuiz
    )

import Browser.Navigation as Nav
import Dict
import Models exposing (Model)
import Msgs exposing (Msg)
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
import String
import Url exposing (Url)


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
                    Cmd.batch [ createQuizSubmission user quizID ]

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
    ( newModel, Cmd.batch ([ Nav.load ("#quiz-submissions/" ++ String.fromInt quizID) ] ++ extraCmds) )


onFetchQuizGrades : Model -> WebData (List QuizGrade) -> ( Model, Cmd Msg )
onFetchQuizGrades model response =
    ( { model | quizGrades = response }, Cmd.none )


onFetchQuizGradeDistributions : Model -> WebData (List QuizGradeDistribution) -> ( Model, Cmd Msg )
onFetchQuizGradeDistributions model response =
    ( { model | quizGradeDistributions = response }, Cmd.none )

{-
    Handle the response we get back when asking for the quiz answers for a
    particular quiz. We're going to do two things:
    1) store the quiz answers so that we can show "SAVED" next
       to particular quiz question options in the interface
    2) update our `quizQuestionOptionInputs` so that if a an
       option is saved it also shows up an initially checked/selected.
-}
onFetchQuizAnswers : Model -> Int -> (WebData (List QuizAnswer)) -> ( Model, Cmd Msg )
onFetchQuizAnswers model quizID response = 
    let
        quizAnswers = Dict.insert quizID response model.quizAnswers 
        selectedInputs = case response of
            RemoteData.Success answers ->
                answers
                |> List.map .quiz_question_option_id
                |> Set.fromList
            _ ->
                model.quizQuestionOptionInputs
        newModel = { model |
            quizAnswers = quizAnswers
            , quizQuestionOptionInputs = selectedInputs
            }
    in
    
    ( newModel, Cmd.none )