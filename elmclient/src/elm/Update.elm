module Update exposing (..)

import Assignments.Commands exposing (createAssignmentSubmission, fetchAssignmentSubmissions, fetchAssignments, sendAssignmentFieldSubmissions)
import Dict exposing (Dict)
import Models exposing (Model)
import Msgs exposing (Msg)
import Navigation exposing (load)
import Quizzes.Commands exposing (createQuizSubmission, fetchQuizSubmissions, fetchQuizzes)
import RemoteData exposing (WebData)
import Routing exposing (parseLocation)


valuesFromDict : Dict comparable b -> List comparable -> List ( comparable, b )
valuesFromDict theDict theList =
    -- Get only the values from the dict where the key is
    -- in the list
    theDict
        |> Dict.filter (\k -> \_ -> List.member k theList)
        |> Dict.toList


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
            case response of
                RemoteData.Success user ->
                    ( { model | currentUser = response }
                    , Cmd.batch
                        [ fetchAssignments user
                        , fetchQuizzes user
                        , fetchAssignmentSubmissions user
                        , fetchQuizSubmissions user
                        ]
                    )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnBeginAssignment assignmentSlug ->
            let
                pba =
                    Dict.insert assignmentSlug RemoteData.Loading model.pendingBeginAssignments
            in
            case model.currentUser of
                RemoteData.Success user ->
                    ( { model | pendingBeginAssignments = pba }, Cmd.batch [ createAssignmentSubmission user.jwt assignmentSlug ] )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnBeginAssignmentComplete assignmentSlug response ->
            case ( model.assignmentSubmissions, response ) of
                ( _, RemoteData.Failure error ) ->
                    ( { model | pendingBeginAssignments = Dict.update assignmentSlug (\_ -> Just (RemoteData.Failure error)) model.pendingBeginAssignments }, Cmd.none )

                ( RemoteData.Success submissions, RemoteData.Success newSubmission ) ->
                    -- Append this submission to the list of existing submissions
                    ( { model | assignmentSubmissions = RemoteData.Success (submissions ++ [ newSubmission ]) }, Cmd.none )

                ( _, _ ) ->
                    -- In other cases do nothing
                    ( model, Cmd.none )

        Msgs.OnSubmitAssignmentFieldSubmissions assignment ->
            let
                fieldIDs =
                    List.map .id assignment.fields

                pendingRequest =
                    Dict.insert assignment.slug RemoteData.Loading model.pendingAssignmentFieldSubmissionRequests

                values =
                    valuesFromDict model.assignmentFieldSubmissionInputs fieldIDs
            in
            case model.currentUser of
                RemoteData.Success user ->
                    ( { model | pendingAssignmentFieldSubmissionRequests = pendingRequest }, Cmd.batch [ sendAssignmentFieldSubmissions user.jwt assignment.slug values ] )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnUpdateAssignmentFieldSubmissionInput assignmentFieldId assignmentFieldValue ->
            ( { model | assignmentFieldSubmissionInputs = Dict.update assignmentFieldId (\_ -> Just assignmentFieldValue) model.assignmentFieldSubmissionInputs }, Cmd.none )

        Msgs.OnSubmitAssignmentFieldSubmissionsResponse assignmentSlug response ->
            -- todo, update the model.assignmentSubmissions
            case ( model.currentUser, model.assignmentSubmissions ) of
                ( RemoteData.Success user, RemoteData.Success submissions ) ->
                    case response of
                        RemoteData.Success newSubmissions ->
                            let
                                pfsrs =
                                    Dict.remove assignmentSlug model.pendingAssignmentFieldSubmissionRequests

                                cmd =
                                    Cmd.batch [ fetchAssignmentSubmissions user ]

                                newModel =
                                    { model | pendingAssignmentFieldSubmissionRequests = pfsrs, assignmentFieldSubmissionInputs = Dict.empty }
                            in
                            -- Lazy for right now - just re-fetch all assignment fiend submissions
                            ( newModel, cmd )

                        _ ->
                            ( model, Cmd.none )

                ( _, _ ) ->
                    ( model, Cmd.none )

        Msgs.OnFetchQuizSubmissions response ->
            ( { model | quizSubmissions = response }, Cmd.none )

        Msgs.OnBeginQuiz quizID ->
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

        Msgs.OnBeginQuizComplete quizID response ->
            let
                newModel =
                    case response of
                        RemoteData.Success quizSubmission ->
                            let
                                newPBQs =
                                    Dict.remove quizID model.pendingBeginQuizzes

                                newQSubs =
                                    case model.quizSubmissions of
                                        RemoteData.Success subs ->
                                            RemoteData.Success (subs ++ [ quizSubmission ])

                                        _ ->
                                            model.quizSubmissions
                            in
                            { model | pendingBeginQuizzes = newPBQs, quizSubmissions = newQSubs }

                        _ ->
                            { model | pendingBeginQuizzes = Dict.insert quizID response model.pendingBeginQuizzes }

                cmds =
                    case response of
                        RemoteData.Success quizSubmission ->
                            Cmd.batch [ load "test" ]

                        _ ->
                            Cmd.none
            in
            ( newModel, cmds )

        Msgs.OnFetchQuizQuestions quizID response ->
            ( model, Cmd.none )
