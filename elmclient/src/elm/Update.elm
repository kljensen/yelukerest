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
import Auth.Model exposing (JWT, isFacultyOrTA)
import Auth.Updates exposing (onFetchCurrentUser)
import Browser exposing (UrlRequest(..))
import Browser.Navigation exposing (load, pushUrl)
import Common.TimeZones
import Dict exposing (Dict)
import Engagements.Commands
    exposing
        ( fetchEngagements
        , maybeSubmitEngagement
        )
import Engagements.Updates
    exposing
        ( onChangeEngagement
        , onSubmitEngagementResponse
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
import ApiTokens.Commands exposing (createApiToken, fetchApiTokens, revokeApiToken)
import ApiTokens.Model exposing (defaultScopes)
import ConnectedApps.Commands exposing (disconnectApp, fetchConnectedApps)
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


{-| Turn what `Engagements.Updates` decided into a command. It reports the
participation to send, if any, rather than building the request itself: it has
no business knowing the signed-in user's JWT.
-}
sendPendingEngagement : JWT -> String -> Int -> ( Model, Maybe String ) -> ( Model, Cmd Msg )
sendPendingEngagement jwt meetingSlug userID ( newModel, toSend ) =
    ( newModel, maybeSubmitEngagement jwt meetingSlug userID toSend )


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
            -- The connected-apps listing is deliberately fetched on every
            -- entry rather than cached: it reflects what Hydra believes right
            -- now, and it carries the CSRF token a disconnect needs.
            ( { model | route = newRoute }
            , case newRoute of
                ConnectedAppsRoute ->
                    fetchConnectedApps

                ApiTokensRoute ->
                    -- Fetched on entry rather than cached, for the same reason
                    -- as the connected-apps listing: last_used_at is the point
                    -- of looking, and a stale value is worse than none.
                    case model.currentUser of
                        RemoteData.Success user ->
                            fetchApiTokens user

                        _ ->
                            Cmd.none

                _ ->
                    Cmd.none
            )

        Msgs.OnFetchApiTokens response ->
            ( { model | apiTokens = response, pendingApiTokenRevokes = Set.empty }, Cmd.none )

        Msgs.SetApiTokenDraftName name ->
            ( { model | apiTokenDraftName = name }, Cmd.none )

        Msgs.SetApiTokenDraftScope scope isChecked ->
            ( { model
                | apiTokenDraftScopes =
                    if isChecked then
                        Set.insert scope model.apiTokenDraftScopes

                    else
                        Set.remove scope model.apiTokenDraftScopes
              }
            , Cmd.none
            )

        Msgs.CreateApiToken ->
            case model.currentUser of
                RemoteData.Success user ->
                    ( model
                    , createApiToken user
                        (String.trim model.apiTokenDraftName)
                        (Set.toList model.apiTokenDraftScopes)
                    )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnCreateApiToken response ->
            case response of
                RemoteData.Success created ->
                    -- Reset the draft back to the read-only default so the next
                    -- token does not silently inherit a write scope the student
                    -- ticked once.
                    ( { model
                        | justCreatedApiToken = Just created
                        , apiTokenDraftName = ""
                        , apiTokenDraftScopes = Set.fromList defaultScopes
                      }
                    , case model.currentUser of
                        RemoteData.Success user ->
                            fetchApiTokens user

                        _ ->
                            Cmd.none
                    )

                _ ->
                    ( model, Cmd.none )

        Msgs.DismissCreatedApiToken ->
            -- Drop the secret from memory as soon as the student says they
            -- have it. It cannot be recovered, which is the point.
            ( { model | justCreatedApiToken = Nothing }, Cmd.none )

        Msgs.RevokeApiToken tokenId ->
            case model.currentUser of
                RemoteData.Success user ->
                    ( { model | pendingApiTokenRevokes = Set.insert tokenId model.pendingApiTokenRevokes }
                    , revokeApiToken user tokenId
                    )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnRevokeApiToken tokenId response ->
            case response of
                RemoteData.Success _ ->
                    -- Refetch: the server decides what is revoked, and
                    -- revoked_at is shown.
                    ( model
                    , case model.currentUser of
                        RemoteData.Success user ->
                            fetchApiTokens user

                        _ ->
                            Cmd.none
                    )

                _ ->
                    ( { model | pendingApiTokenRevokes = Set.remove tokenId model.pendingApiTokenRevokes }
                    , Cmd.none
                    )

        Msgs.OnFetchConnectedApps response ->
            ( { model | connectedApps = response, pendingDisconnects = Set.empty }, Cmd.none )

        Msgs.DisconnectApp csrfToken clientId ->
            ( { model | pendingDisconnects = Set.insert clientId model.pendingDisconnects }
            , disconnectApp csrfToken clientId
            )

        Msgs.OnDisconnectApp clientId result ->
            case result of
                Ok () ->
                    -- Refetch rather than removing the row locally: the server
                    -- is the authority on what is still connected, and the
                    -- next disconnect needs a fresh CSRF token anyway.
                    ( model, fetchConnectedApps )

                Err _ ->
                    -- Leave the list as it was and let the button come back,
                    -- so a failed disconnect does not look like a successful
                    -- one.
                    ( { model | pendingDisconnects = Set.remove clientId model.pendingDisconnects }
                    , Cmd.none
                    )

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
            onFetchCurrentUser response model

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
            case model.currentUser of
                RemoteData.Success user ->
                    onChangeEngagement meetingSlug userID level model
                        |> sendPendingEngagement user.jwt meetingSlug userID

                _ ->
                    ( model, Cmd.none )

        Msgs.OnSubmitEngagementResponse meetingSlug userID response ->
            case model.currentUser of
                RemoteData.Success user ->
                    onSubmitEngagementResponse meetingSlug userID response model
                        |> sendPendingEngagement user.jwt meetingSlug userID

                _ ->
                    ( model, Cmd.none )

        Msgs.OnFetchTimeZone z ->
            let
                tz1 =
                    model.timeZone

                tz2 =
                    { tz1 | zone = Common.TimeZones.zoneForZoneName tz1.zoneName z }
            in
            ( { model | timeZone = tz2 }, Cmd.none )

        Msgs.OnFetchTimeZoneName zoneName ->
            let
                tz1 =
                    model.timeZone

                tz2 =
                    { tz1
                        | zoneName = zoneName
                        , zone = Common.TimeZones.zoneForZoneName zoneName tz1.zone
                    }
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
