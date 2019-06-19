module Assignments.Updates exposing
    ( onFetchAssignmentGradeDistributions
    , onFetchAssignmentGrades
    )

import Assignments.Model
    exposing
        ( AssignmentGrade
        , AssignmentGradeDistribution
        )
import Models exposing (Model)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


onFetchAssignmentGrades : Model -> WebData (List AssignmentGrade) -> ( Model, Cmd Msg )
onFetchAssignmentGrades model response =
    ( { model | assignmentGrades = response }, Cmd.none )


onFetchAssignmentGradeDistributions : Model -> WebData (List AssignmentGradeDistribution) -> ( Model, Cmd Msg )
onFetchAssignmentGradeDistributions model response =
    ( { model | assignmentGradeDistributions = response }, Cmd.none )
