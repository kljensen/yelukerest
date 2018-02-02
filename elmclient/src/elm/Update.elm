module Update exposing (..)

import Assignments.Commands exposing (fetchAssignmentSubmissions, fetchAssignments)
import Dict exposing (Dict)
import Models exposing (Model)
import Msgs exposing (Msg)
import Quizzes.Commands exposing (fetchQuizzes)
import RemoteData exposing (WebData)
import Routing exposing (parseLocation)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Msgs.OnLocationChange location ->
            let
                newRoute =
                    parseLocation location
            in
            ( { model | route = newRoute }, Cmd.none )

        Msgs.OnFetchDate d ->
            ( { model | current_date = Just d }, Cmd.none )

        Msgs.OnFetchMeetings response ->
            ( { model | meetings = response }, Cmd.none )

        Msgs.OnFetchAssignments response ->
            ( { model | assignments = response }, Cmd.none )

        Msgs.OnFetchAssignmentSubmissions response ->
            ( { model | assignmentSubmissions = response }, Cmd.none )

        Msgs.OnFetchQuizzes response ->
            ( { model | quizzes = response }, Cmd.none )

        Msgs.OnFetchCurrentUser response ->
            ( { model | currentUser = response }, Cmd.batch [ fetchAssignments response, fetchQuizzes response, fetchAssignmentSubmissions response ] )

        Msgs.OnBeginAssignment assignment_slug ->
            let
                pba =
                    Dict.insert assignment_slug RemoteData.Loading model.pendingBeginAssignments
            in
            ( { model | pendingBeginAssignments = pba }, Cmd.none )
