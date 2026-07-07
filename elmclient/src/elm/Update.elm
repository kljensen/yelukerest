module Update exposing (listToDict, update, valuesFromDict)

import Assignments.Commands
    exposing
        ( createAssignmentSubmission
        , fetchAssignmentGradeDistributions
        , fetchAssignmentGradeExceptions
        , fetchAssignmentGrades
        , fetchAssignmentSubmissions
        , fetchAssignments
        , sendAssignmentFieldSubmissions
        )
import Assignments.Model exposing (valuesForSubmissionID)
import Assignments.Updates
    exposing
        ( onFetchAssignmentGradeDistributions
        , onFetchAssignmentGrades
        )
import Auth.Model exposing (isFacultyOrTA)
import Browser exposing (UrlRequest(..))
import Browser.Navigation exposing (load, pushUrl)
import Dict exposing (Dict)
import Engagements.Commands
    exposing
        ( fetchEngagements
        , submitEngagement
        )
import Models exposing (Model, Route(..))
import Msgs exposing (BrowserLocation(..), Msg)
import Quizzes.Commands
    exposing
        ( fetchQuizArtifacts
        , fetchQuizGradeDistributions
        , fetchQuizGrades
        , fetchQuizSubmissions
        , fetchQuizzes
        )
import Quizzes.Updates
    exposing
        ( onFetchQuizArtifacts
        , onFetchQuizGradeDistributions
        , onFetchQuizGrades
        , onFetchQuizSubmissions
        )
import RemoteData exposing (WebData)
import Routing exposing (parseLocation)
import Set
import Time exposing (Posix)
import Url
import Users.Commands exposing (fetchUserSecrets, fetchUsers)


valuesFromDict : Dict comparable b -> List comparable -> List ( comparable, b )
valuesFromDict theDict theList =
    -- Get only the values from the dict where the key is
    -- in the list
    theDict
        |> Dict.filter (\k -> \_ -> List.member k theList)
        |> Dict.toList


listToDict : (a -> comparable) -> List a -> Dict.Dict comparable a
listToDict getKey values =
    -- https://gist.github.com/Warry/b4382a5b4373de57f5ba
    Dict.fromList (List.map (\v -> ( getKey v, v )) values)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Msgs.LinkClicked urlRequest ->
            case urlRequest of
                Internal url ->
                    case parseLocation (UrlLocation url) of
                        NotFoundRoute ->
                            ( model, load (Url.toString url) )

                        _ ->
                            ( model, pushUrl model.navKey (Url.toString url) )

                External href ->
                    ( model, load href )

        Msgs.OnLocationChange location ->
            let
                newRoute =
                    parseLocation location
            in
            ( { model | route = newRoute }, Cmd.none )

        Msgs.Tick theTime ->
            ( { model | current_date = Just theTime }, Cmd.none )

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
                    let
                        newUserModel =
                            { model | currentUser = response }

                        newUserCmds =
                            Cmd.batch
                                [ fetchAssignments user
                                , fetchQuizzes user
                                , fetchQuizGradeDistributions user
                                , fetchAssignmentSubmissions user
                                , fetchQuizSubmissions user
                                , fetchQuizArtifacts user
                                , fetchQuizGrades user
                                , fetchQuizGradeDistributions user
                                , fetchAssignmentGrades user
                                , fetchAssignmentGradeDistributions user
                                , fetchAssignmentGradeExceptions user
                                , fetchUserSecrets user
                                ]

                    in
                    if isFacultyOrTA user.role then
                        ( newUserModel
                        , Cmd.batch
                            [ newUserCmds
                            , fetchEngagements user
                            , fetchUsers user
                            ]
                        )

                    else
                        ( newUserModel, newUserCmds )

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

        Msgs.OnSubmitAssignmentFieldSubmissions assignmentSubmission ->
            let
                -- Have the submission id. Need to submit the assignmentSubmissionField tuples
                values =
                    valuesForSubmissionID assignmentSubmission.id model.assignmentFieldSubmissionInputs

                pendingRequest =
                    Dict.insert assignmentSubmission.assignment_slug RemoteData.Loading model.pendingAssignmentFieldSubmissionRequests
            in
            case model.currentUser of
                RemoteData.Success user ->
                    ( { model | pendingAssignmentFieldSubmissionRequests = pendingRequest }
                    , Cmd.batch
                        [ sendAssignmentFieldSubmissions user.jwt assignmentSubmission.assignment_slug values
                        ]
                    )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnUpdateAssignmentFieldSubmissionInput submissionID assignmentFieldSlug assignmentFieldValue ->
            let
                key =
                    ( submissionID, assignmentFieldSlug )

                newAfsi =
                    Dict.update key (\_ -> Just assignmentFieldValue) model.assignmentFieldSubmissionInputs
            in
            ( { model | assignmentFieldSubmissionInputs = newAfsi }, Cmd.none )

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
            onFetchQuizSubmissions model response

        Msgs.OnFetchQuizArtifacts response ->
            onFetchQuizArtifacts model response

        Msgs.OnFetchQuizGrades response ->
            onFetchQuizGrades model response

        Msgs.OnFetchQuizGradeDistributions response ->
            onFetchQuizGradeDistributions model response

        Msgs.OnFetchAssignmentGrades response ->
            onFetchAssignmentGrades model response

        Msgs.OnFetchAssignmentGradeDistributions response ->
            onFetchAssignmentGradeDistributions model response

        Msgs.OnFetchAssignmentGradeExceptions assignmentGradeExceptions ->
            ( { model | assignmentGradeExceptions = assignmentGradeExceptions }, Cmd.none )

        Msgs.OnFetchUserSecrets userSecrets ->
            ( { model | userSecrets = userSecrets }, Cmd.none )

        Msgs.OnFetchEngagements response ->
            ( { model | engagements = response }, Cmd.none )

        Msgs.OnFetchUsers response ->
            ( { model | users = response }, Cmd.none )

        Msgs.OnChangeEngagement meetingSlug userID level ->
            let
                npses =
                    Dict.insert ( meetingSlug, userID ) RemoteData.Loading model.pendingSubmitEngagements

                newModel =
                    { model | pendingSubmitEngagements = npses }
            in
            case model.currentUser of
                RemoteData.Success user ->
                    ( newModel, submitEngagement user.jwt meetingSlug userID level )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnSubmitEngagementResponse meetingSlug userID response ->
            let
                pses =
                    case response of
                        RemoteData.Success _ ->
                            Dict.remove ( meetingSlug, userID ) model.pendingSubmitEngagements

                        _ ->
                            Dict.insert ( meetingSlug, userID ) response model.pendingSubmitEngagements
            in
            ( { model | pendingSubmitEngagements = pses }, Cmd.none )

        Msgs.OnFetchTimeZone z ->
            let
                tz1 =
                    model.timeZone

                tz2 =
                    { tz1 | zone = z }
            in
            ( { model | timeZone = tz2 }, Cmd.none )

        Msgs.OnFetchTimeZoneName zoneName ->
            let
                tz1 =
                    model.timeZone

                tz2 =
                    { tz1 | zoneName = zoneName }
            in
            ( { model | timeZone = tz2 }, Cmd.none )

        Msgs.ToggleShowUserSecret slug ->
            let
                s =
                    case Set.member slug model.userSecretsToShow of
                        True ->
                            Set.remove slug model.userSecretsToShow

                        False ->
                            Set.insert slug model.userSecretsToShow
            in
            ( { model | userSecretsToShow = s }, Cmd.none )

        Msgs.OnChangeEngagementUserQuery userQuery ->
            ( { model | engagementUserQuery = Just userQuery }, Cmd.none )
