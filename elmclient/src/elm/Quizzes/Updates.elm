module Quizzes.Updates exposing
    ( onFetchQuizGradeDistributions
    , onFetchQuizGrades
    , onFetchQuizSubmissions
    )

import Models exposing (Model)
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( QuizGrade
        , QuizGradeDistribution
        , QuizSubmission
        )
import RemoteData exposing (WebData)


onFetchQuizSubmissions : Model -> WebData (List QuizSubmission) -> ( Model, Cmd Msg )
onFetchQuizSubmissions model response =
    ( { model | quizSubmissions = response }, Cmd.none )


onFetchQuizGrades : Model -> WebData (List QuizGrade) -> ( Model, Cmd Msg )
onFetchQuizGrades model response =
    ( { model | quizGrades = response }, Cmd.none )


onFetchQuizGradeDistributions : Model -> WebData (List QuizGradeDistribution) -> ( Model, Cmd Msg )
onFetchQuizGradeDistributions model response =
    ( { model | quizGradeDistributions = response }, Cmd.none )
