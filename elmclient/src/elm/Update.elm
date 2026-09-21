module Update exposing (listToDict, update, valuesFromDict)

import Assignments.Commands
    exposing
        ( beginAndSendAssignmentFieldSubmissions
        , createAssignmentSubmission
        , createRepository
        , fetchAssignmentGradeDistributions
        , fetchAssignmentGradeExceptions
        , fetchAssignmentGrades
        , fetchAssignmentSubmissions
        , fetchAssignments
        , loadRepository
        , sendAssignmentFieldSubmissions
        )
import Assignments.Model
import Assignments.Updates
    exposing
        ( RepositoryRequest(..)
        , adoptDrafts
        , onBeginAndSubmitResponse
        , onCreateRepository
        , onCreateRepositoryResponse
        , onEnterAssignment
        , onFetchAssignmentGradeDistributions
        , onFetchAssignmentGrades
        , onGithubJoinReturn
        , onLoadRepository
        , onLoadRepositoryResponse
        , onRepositoryPollTick
        , onSubmitAnswers
        , onSubmitResponse
        , onUpdateDraftInput
        )
import Auth.Model exposing (CurrentUser, JWT, isFaculty, isFacultyOrTA)
import Auth.Updates exposing (onFetchCurrentUser)
import Browser exposing (UrlRequest(..))
import Browser.Navigation exposing (load, pushUrl, replaceUrl)
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
import DataGrants.Commands exposing (createDataGrant, fetchDataGrants, revokeDataGrant)
import DataGrants.Model
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


{-| The signed-in user if they are faculty, else nothing. Every data-grant
request goes through this: the RPCs and the view refuse other roles, so
no other role should ask.
-}
facultyUser : Model -> Maybe CurrentUser
facultyUser model =
    case model.currentUser of
        RemoteData.Success user ->
            if isFaculty user.role then
                Just user

            else
                Nothing

        _ ->
            Nothing


{-| Turn what `Assignments.Updates` decided about a repository into commands.
The submissions refetch is the one that needs the signed-in user.
-}
sendRepositoryRequests : ( Model, List RepositoryRequest ) -> ( Model, Cmd Msg )
sendRepositoryRequests ( newModel, requests ) =
    let
        toCmd request =
            case request of
                CreateRequest slug generation ->
                    createRepository slug generation

                LoadRequest slug generation ->
                    loadRepository slug generation

                RefetchSubmissions ->
                    case newModel.currentUser of
                        RemoteData.Success user ->
                            fetchAssignmentSubmissions user

                        _ ->
                            Cmd.none
    in
    ( newModel, Cmd.batch (List.map toCmd requests) )


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

                -- Only a change of route is an entry to an assignment's
                -- page. The one way the URL changes to the route already
                -- shown is the replaceUrl that strips a GitHub join marker,
                -- and re-checking the repository then would overwrite what
                -- the marker just said.
                enterAssignment =
                    if newRoute == model.route then
                        identity

                    else
                        enterAssignmentIfDetailRoute
            in
            -- The connected-apps listing is deliberately fetched on every
            -- entry rather than cached: it reflects what Hydra believes right
            -- now, and it carries the CSRF token a disconnect needs.
            ( { model
                | route = newRoute

                -- The one-time credential must not outlive the page it was
                -- shown on: navigating away and back would show it again.
                , justCreatedDataGrant =
                    if newRoute == DataGrantsRoute then
                        model.justCreatedDataGrant

                    else
                        Nothing
              }
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

                DataGrantsRoute ->
                    -- Fetched on entry, like the tokens: another faculty
                    -- member may have revoked one since the last look.
                    case facultyUser model of
                        Just user ->
                            fetchDataGrants user

                        Nothing ->
                            Cmd.none

                _ ->
                    Cmd.none
            )
                |> enterAssignment

        Msgs.OnFetchDataGrants response ->
            ( { model | dataGrants = response, pendingDataGrantRevokes = Set.empty }, Cmd.none )

        Msgs.SetDataGrantDraftName name ->
            ( { model | dataGrantDraft = DataGrants.Model.setDraftName name model.dataGrantDraft }, Cmd.none )

        Msgs.SetDataGrantDraftExpiry date ->
            ( { model | dataGrantDraft = DataGrants.Model.setDraftExpiry date model.dataGrantDraft }, Cmd.none )

        Msgs.AddDataGrantDraftAssignment ->
            ( { model | dataGrantDraft = DataGrants.Model.addDraftAssignment model.dataGrantDraft }, Cmd.none )

        Msgs.RemoveDataGrantDraftAssignment index ->
            ( { model | dataGrantDraft = DataGrants.Model.removeDraftAssignment index model.dataGrantDraft }, Cmd.none )

        Msgs.SetDataGrantDraftAssignmentSlug index slug ->
            ( { model | dataGrantDraft = DataGrants.Model.setDraftAssignmentSlug index slug model.dataGrantDraft }, Cmd.none )

        Msgs.SetDataGrantDraftIdentity index attribute isChecked ->
            ( { model | dataGrantDraft = DataGrants.Model.setDraftIdentity index attribute isChecked model.dataGrantDraft }, Cmd.none )

        Msgs.SetDataGrantDraftField index fieldSlug isChecked ->
            ( { model | dataGrantDraft = DataGrants.Model.setDraftField index fieldSlug isChecked model.dataGrantDraft }, Cmd.none )

        Msgs.CreateDataGrant ->
            case facultyUser model of
                Just user ->
                    ( { model | dataGrantCreateError = Nothing, justCreatedDataGrant = Nothing }
                    , createDataGrant user model.dataGrantDraft
                    )

                Nothing ->
                    ( model, Cmd.none )

        Msgs.OnCreateDataGrant result ->
            case ( model.route, result ) of
                ( DataGrantsRoute, Ok created ) ->
                    -- Reset the form: a grant is immutable, so the next one is
                    -- a fresh decision rather than an edit of this one.
                    ( { model
                        | justCreatedDataGrant = Just created
                        , dataGrantCreateError = Nothing
                        , dataGrantDraft = DataGrants.Model.emptyDraft
                      }
                    , case facultyUser model of
                        Just user ->
                            fetchDataGrants user

                        Nothing ->
                            Cmd.none
                    )

                ( DataGrantsRoute, Err message ) ->
                    -- Keep the draft: the message says what to fix.
                    ( { model | dataGrantCreateError = Just message }, Cmd.none )

                _ ->
                    -- The user left the page before the reply arrived. The
                    -- credential is never shown anywhere but that page, so
                    -- it is dropped here; the grant itself is in the listing
                    -- and can be revoked.
                    ( model, Cmd.none )

        Msgs.DismissCreatedDataGrant ->
            -- Drop the credential from memory as soon as it has been copied.
            ( { model | justCreatedDataGrant = Nothing }, Cmd.none )

        Msgs.RevokeDataGrant grantId ->
            case facultyUser model of
                Just user ->
                    ( { model | pendingDataGrantRevokes = Set.insert grantId model.pendingDataGrantRevokes }
                    , revokeDataGrant user grantId
                    )

                Nothing ->
                    ( model, Cmd.none )

        Msgs.OnRevokeDataGrant grantId response ->
            case response of
                RemoteData.Success _ ->
                    -- Refetch: the server records who revoked it and when,
                    -- and a repeat revoke leaves the first record in place.
                    ( model
                    , case facultyUser model of
                        Just user ->
                            fetchDataGrants user

                        Nothing ->
                            Cmd.none
                    )

                _ ->
                    ( { model | pendingDataGrantRevokes = Set.remove grantId model.pendingDataGrantRevokes }
                    , Cmd.none
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
            -- A reload of #/assignments/<slug> sets the route before the
            -- assignments arrive, so the repository check on route change
            -- had nothing to go on; do it now.
            ( { model | assignments = response }, Cmd.none )
                |> enterAssignmentIfDetailRoute

        Msgs.OnCreateRepository slug ->
            onCreateRepository slug model |> sendRepositoryRequests

        Msgs.OnCreateRepositoryResponse slug generation now result ->
            onCreateRepositoryResponse slug generation now result model |> sendRepositoryRequests

        Msgs.OnLoadRepository slug ->
            onLoadRepository slug model |> sendRepositoryRequests

        Msgs.OnLoadRepositoryResponse slug generation now result ->
            onLoadRepositoryResponse slug generation now result model |> sendRepositoryRequests

        Msgs.OnRepositoryPollTick now ->
            onRepositoryPollTick now model |> sendRepositoryRequests

        Msgs.OnFetchAssignmentSubmissions response ->
            -- Answers typed before a submission existed move under its id
            -- as soon as it shows up; see `Assignments.Updates.adoptDrafts`.
            ( case ( model.currentUser, response ) of
                ( RemoteData.Success user, RemoteData.Success submissions ) ->
                    adoptDrafts user submissions { model | assignmentSubmissions = response }

                _ ->
                    { model | assignmentSubmissions = response }
            , Cmd.none
            )

        Msgs.OnFetchQuizzes response ->
            ( { model | quizzes = response }, Cmd.none )

        Msgs.OnFetchCurrentUser response ->
            let
                ( newModel, cmd ) =
                    onFetchCurrentUser response model
            in
            -- A direct load or reload of #/data-grants sets the route in init,
            -- before anyone is signed in, so the fetch on route change never
            -- fires. Issue it here instead, once we know who this is.
            ( newModel
            , case ( newModel.route, facultyUser newModel ) of
                ( DataGrantsRoute, Just user ) ->
                    Cmd.batch [ cmd, fetchDataGrants user ]

                _ ->
                    cmd
            )

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
            case ( model.currentUser, onSubmitAnswers assignmentSubmission.assignment_slug (Just assignmentSubmission.id) model ) of
                ( RemoteData.Success user, ( newModel, Just values ) ) ->
                    ( newModel, sendAssignmentFieldSubmissions user.jwt assignmentSubmission.assignment_slug values )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnBeginAndSubmitAssignmentFieldSubmissions assignmentSlug ->
            case ( model.currentUser, onSubmitAnswers assignmentSlug Nothing model ) of
                ( RemoteData.Success user, ( newModel, Just values ) ) ->
                    ( newModel, beginAndSendAssignmentFieldSubmissions user.jwt assignmentSlug values )

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

        Msgs.OnUpdateAssignmentDraftInput assignmentSlug assignmentFieldSlug assignmentFieldValue ->
            ( onUpdateDraftInput assignmentSlug assignmentFieldSlug assignmentFieldValue model, Cmd.none )

        Msgs.OnSubmitAssignmentFieldSubmissionsResponse assignmentSlug response ->
            -- Lazy for right now - just re-fetch all assignment field submissions
            onSubmitResponse assignmentSlug response model
                |> refetchSubmissionsIf

        Msgs.OnBeginAndSubmitAssignmentFieldSubmissionsResponse assignmentSlug result ->
            onBeginAndSubmitResponse assignmentSlug result model
                |> refetchSubmissionsIf

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


{-| Turn what the answers handlers decided into the refetch they asked for.
-}
refetchSubmissionsIf : ( Model, Bool ) -> ( Model, Cmd Msg )
refetchSubmissionsIf ( model, refetch ) =
    case ( refetch, model.currentUser ) of
        ( True, RemoteData.Success user ) ->
            ( model, fetchAssignmentSubmissions user )

        _ ->
            ( model, Cmd.none )


{-| If the page is an assignment's, ask where its repository stands (see
`Assignments.Updates.onEnterAssignment`), on top of whatever else the
transition already asked for.

If it is an assignment's as the GitHub join sends the student back to it,
act on the join's result instead and drop the marker from the URL, so a
reload or a copied link does not act on it again. Both wait for the
assignments to be loaded, since a direct load of the page sets the route
before they are.

-}
enterAssignmentIfDetailRoute : ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
enterAssignmentIfDetailRoute ( model, cmd ) =
    case ( model.route, model.assignments ) of
        ( AssignmentDetailRoute slug, RemoteData.Success _ ) ->
            let
                ( newModel, repositoryCmd ) =
                    onEnterAssignment slug model |> sendRepositoryRequests
            in
            ( newModel, Cmd.batch [ cmd, repositoryCmd ] )

        ( AssignmentJoinReturnRoute slug result, RemoteData.Success _ ) ->
            let
                ( newModel, repositoryCmd ) =
                    onGithubJoinReturn slug result { model | route = AssignmentDetailRoute slug }
                        |> sendRepositoryRequests
            in
            ( newModel
            , Cmd.batch [ cmd, repositoryCmd, replaceUrl model.navKey ("#/assignments/" ++ slug) ]
            )

        _ ->
            ( model, cmd )
