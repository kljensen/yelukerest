module Assignments.Updates exposing
    ( SubmissionState
    , onFetchAssignmentGradeDistributions
    , onFetchAssignmentGrades
    , onSubmitAssignmentFieldSubmissionsResponse
    , studentEnteringAssignment
    )

import Assignments.Model
    exposing
        ( AssignmentFieldSubmission
        , AssignmentFieldSubmissionInputs
        , AssignmentGrade
        , AssignmentGradeDistribution
        , AssignmentSlug
        , PendingAssignmentFieldSubmissionRequests
        )
import Auth.Model exposing (CurrentUser, isStudent)
import Dict
import Models exposing (Model, Route(..))
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


onFetchAssignmentGrades : Model -> WebData (List AssignmentGrade) -> ( Model, Cmd Msg )
onFetchAssignmentGrades model response =
    ( { model | assignmentGrades = response }, Cmd.none )


onFetchAssignmentGradeDistributions : Model -> WebData (List AssignmentGradeDistribution) -> ( Model, Cmd Msg )
onFetchAssignmentGradeDistributions model response =
    ( { model | assignmentGradeDistributions = response }, Cmd.none )


{-| The slice of the model that saving a submission's fields touches. An
extensible record, as in `Engagements.Updates`, so tests can drive it
without a `Browser.Navigation.Key`.
-}
type alias SubmissionState a =
    { a
        | pendingAssignmentFieldSubmissionRequests : PendingAssignmentFieldSubmissionRequests
        , assignmentFieldSubmissionInputs : AssignmentFieldSubmissionInputs
    }


{-| The outcome of one save. True means the submissions should be fetched
again; `Update` builds that request, which needs the user's JWT.

The inputs are kept on success. They are bound to the form's inputs, so
clearing them would blank what the student just saved; and they are what was
saved, so a second Submit is a harmless upsert.

-}
onSubmitAssignmentFieldSubmissionsResponse : AssignmentSlug -> WebData (List AssignmentFieldSubmission) -> SubmissionState a -> ( SubmissionState a, Bool )
onSubmitAssignmentFieldSubmissionsResponse assignmentSlug response state =
    case response of
        RemoteData.Success _ ->
            ( { state | pendingAssignmentFieldSubmissionRequests = Dict.remove assignmentSlug state.pendingAssignmentFieldSubmissionRequests }
            , True
            )

        _ ->
            ( state, False )


{-| The signed-in student arriving at an assignment page, if that is what
this route change is. `Update` refetches my\_repositories for them: a
repository created on the repositories page since sign-in would otherwise
never be offered, and neither would one whose first fetch failed.
-}
studentEnteringAssignment : Route -> WebData CurrentUser -> Maybe CurrentUser
studentEnteringAssignment route wdCurrentUser =
    case ( route, wdCurrentUser ) of
        ( AssignmentDetailRoute _, RemoteData.Success user ) ->
            if isStudent user.role then
                Just user

            else
                Nothing

        _ ->
            Nothing
