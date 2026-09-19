module Assignments.Updates exposing
    ( RepositoryFlowState
    , RepositoryRequest(..)
    , isPollingActiveRoute
    , onCreateRepository
    , onCreateRepositoryResponse
    , onEnterAssignment
    , onFetchAssignmentGradeDistributions
    , onFetchAssignmentGrades
    , onGithubJoinReturn
    , onLoadRepository
    , onLoadRepositoryResponse
    , onRepositoryPollTick
    , pollTimeoutMillis
    )

import Assignments.Commands exposing (githubJoinUrl)
import Assignments.Model
    exposing
        ( Assignment
        , AssignmentGrade
        , AssignmentGradeDistribution
        , AssignmentRepositories
        , AssignmentSlug
        , GithubJoinResult(..)
        , PollingRepository
        , RepositoryError
        , RepositoryGenerations
        , RepositoryProgress(..)
        , RepositoryState(..)
        , RepositoryStatus
        , usesRepositoryFlow
        )
import Auth.Model exposing (CurrentUser)
import Dict
import Models exposing (Model, Route(..))
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Time exposing (Posix)


onFetchAssignmentGrades : Model -> WebData (List AssignmentGrade) -> ( Model, Cmd Msg )
onFetchAssignmentGrades model response =
    ( { model | assignmentGrades = response }, Cmd.none )


onFetchAssignmentGradeDistributions : Model -> WebData (List AssignmentGradeDistribution) -> ( Model, Cmd Msg )
onFetchAssignmentGradeDistributions model response =
    ( { model | assignmentGradeDistributions = response }, Cmd.none )



-- Self-serve assignment repositories (issue #397)


{-| The slice of the model the repository flow touches. An extensible record
for the reason `Engagements.Updates.EngagementState` is: the full model holds
a `Browser.Navigation.Key` no test can construct, and these transitions are
the part worth testing.

`route` is here because polling is confined to the assignment on screen,
and `current_date` because the buttons a rate limit turned off stay off
until it is over.

-}
type alias RepositoryFlowState a =
    { a
        | assignments : WebData (List Assignment)
        , assignmentRepositories : AssignmentRepositories
        , repositoryGenerations : RepositoryGenerations
        , currentUser : WebData CurrentUser
        , current_date : Maybe Posix
        , route : Route
    }


{-| What a transition wants sent. `Update` turns these into commands; the
submissions refetch needs the signed-in user, which this module has no
business knowing. The number on a request is the one its reply must carry
back to be taken.
-}
type RepositoryRequest
    = CreateRequest AssignmentSlug Int
    | LoadRequest AssignmentSlug Int
    | RefetchSubmissions


{-| How long to wait for GitHub's copy before handing the student a manual
"Check again" button instead of polling on. The copy usually takes seconds;
two minutes is long enough that giving up says something is wrong.
-}
pollTimeoutMillis : Int
pollTimeoutMillis =
    2 * 60 * 1000


{-| Whether the poll timer should be running: only for the assignment on
screen, and only while its copy is being waited on. A copy left behind by
navigating away keeps its `Polling` entry, so the page can show the link
on return, but nothing asks after it until then.
-}
isPollingActiveRoute : RepositoryFlowState a -> Bool
isPollingActiveRoute state =
    case activePolling state of
        Just _ ->
            True

        Nothing ->
            False


{-| The student has arrived at an assignment's page (by navigation, or by
the assignments loading under a page they reloaded on). Ask the server where
its repository stands, so the page shows that rather than whatever this
session last saw.

A creation in flight is left alone: its answer is on the way. So is a
check already out. A copy that was being polled when the student left is
asked after again now that they are back, since the timer stopped with
them. Otherwise the last known state stays on screen until the answer
replaces it, rather than flashing "Checking..." on every visit; `Checking`
is only for a first look.

-}
onEnterAssignment : AssignmentSlug -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
onEnterAssignment slug state =
    if not (usesFlow slug state) then
        ( state, [] )

    else
        case Dict.get slug state.assignmentRepositories of
            Just Creating ->
                ( state, [] )

            Just Checking ->
                ( state, [] )

            Just (Polling polling) ->
                load slug (setProgress slug (Polling { polling | inFlight = True }) state)

            Just _ ->
                load slug state

            Nothing ->
                load slug (setProgress slug Checking state)


{-| A click on "Create my repository" (or "Resume", or the "Try again" under
a prerequisite message: all of them ask the server to go ahead). Nothing is
sent while a creation or a copy is already under way, so a double click
cannot start a second one, nor while a rate limit's hold is on.
-}
onCreateRepository : AssignmentSlug -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
onCreateRepository slug state =
    case Dict.get slug state.assignmentRepositories of
        Just Creating ->
            ( state, [] )

        Just (Polling _) ->
            ( state, [] )

        Just (Blocked blocked) ->
            if onHold blocked.notBefore state then
                ( state, [] )

            else
                create slug state

        Just (Failed failed) ->
            if onHold failed.notBefore state then
                ( state, [] )

            else
                create slug state

        _ ->
            create slug state


{-| The answer to a create. It is only taken while this assignment is
`Creating` and the number matches: anything else answers a request this
session has since moved past.

`ready` also refetches the submissions: the server recorded the repository
URL in the assignment's URL field, and the page shows that from the
submissions it holds.

-}
onCreateRepositoryResponse : AssignmentSlug -> Int -> Posix -> Result RepositoryError RepositoryStatus -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
onCreateRepositoryResponse slug generation now result state =
    case ( isCurrent slug generation state, Dict.get slug state.assignmentRepositories, result ) of
        ( True, Just Creating, Ok status ) ->
            settle slug now status state

        ( True, Just Creating, Err error ) ->
            ( fail slug now error state, [] )

        _ ->
            ( state, [] )


{-| A manual status check: "Check again" once polling has given up, or "Try
again" after a failure. After a failed create in particular, asking rather
than creating again is the point: the server knows whether the earlier
attempt landed, and its answer leads to the right button.

Ignored while a request is already out for this assignment, and while a
rate limit's hold is on.

-}
onLoadRepository : AssignmentSlug -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
onLoadRepository slug state =
    case Dict.get slug state.assignmentRepositories of
        Just Creating ->
            ( state, [] )

        Just Checking ->
            ( state, [] )

        Just (Polling polling) ->
            if polling.inFlight then
                ( state, [] )

            else
                load slug (setProgress slug (Polling { polling | inFlight = True }) state)

        Just (Failed failed) ->
            if onHold failed.notBefore state then
                ( state, [] )

            else
                load slug (setProgress slug Checking state)

        _ ->
            load slug (setProgress slug Checking state)


{-| The answer to a status check, whether from a poll, a page entry or a
manual check. Dropped unless its number is current: a check that was out
when the student clicked "Create" must not answer after the create did.

Otherwise the server's word wins, with two exceptions that keep the poll
bounded: a retryable failure during polling (GitHub flickering, a rate
limit) keeps polling rather than ending it, holding off by `Retry-After` if
one was given; and `copying` after polling has given up does not quietly
start polling again, since a late reply to the poll that timed out would
otherwise undo the timeout.

-}
onLoadRepositoryResponse : AssignmentSlug -> Int -> Posix -> Result RepositoryError RepositoryStatus -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
onLoadRepositoryResponse slug generation now result state =
    if not (isCurrent slug generation state) then
        ( state, [] )

    else
        case result of
            Ok status ->
                settle slug now status state

            Err error ->
                if error.code == "repository_not_started" then
                    ( setProgress slug NotStarted state, [] )

                else
                    case Dict.get slug state.assignmentRepositories of
                        Just (Polling polling) ->
                            if error.retryable then
                                ( setProgress slug
                                    (Polling
                                        { polling
                                            | inFlight = False
                                            , notBefore = Maybe.map (\seconds -> addSeconds seconds now) error.retryAfterSeconds
                                        }
                                    )
                                    state
                                , []
                                )

                            else
                                ( fail slug now error state, [] )

                        _ ->
                            ( fail slug now error state, [] )


{-| The poll timer, for the assignment on screen only. It gets one status
request at a time, none before a `Retry-After` hold is over, and none at
all once it has been waited on for `pollTimeoutMillis`.
-}
onRepositoryPollTick : Posix -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
onRepositoryPollTick now state =
    case activePolling state of
        Just ( slug, polling ) ->
            if millisBetween polling.since now >= pollTimeoutMillis then
                ( setProgress slug (PollTimedOut polling.last) state, [] )

            else if polling.inFlight || isBefore now polling.notBefore then
                ( state, [] )

            else
                load slug (setProgress slug (Polling { polling | inFlight = True }) state)

        Nothing ->
            ( state, [] )


{-| Record a status the server reported, from either request.

`ready` refetches the submissions whenever it lands for the assignment on
screen, even if the repository was already known to be done: a `ready`
that arrived while the student was on another page did not refetch (the
page that shows the URL field was not up), so the check on their return
has to.

-}
settle : AssignmentSlug -> Posix -> RepositoryStatus -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
settle slug now status state =
    let
        previous =
            Dict.get slug state.assignmentRepositories
    in
    case status.state of
        Ready ->
            ( setProgress slug (Done status) state
            , if state.route == AssignmentDetailRoute slug then
                [ RefetchSubmissions ]

              else
                []
            )

        Copying ->
            case previous of
                Just (Polling polling) ->
                    ( setProgress slug (Polling { polling | last = status, inFlight = False, notBefore = Nothing }) state, [] )

                Just (PollTimedOut _) ->
                    ( setProgress slug (PollTimedOut status) state, [] )

                _ ->
                    ( setProgress slug (Polling { since = now, last = status, inFlight = False, notBefore = Nothing }) state, [] )

        NeedsGithubLink ->
            ( setProgress slug (Blocked { status = status, notBefore = Nothing, joinCancelled = False }) state, [] )

        NeedsOrgJoin ->
            ( setProgress slug (Blocked { status = status, notBefore = Nothing, joinCancelled = False }) state, [] )


{-| The student is back from the GitHub organization join (issue #399),
and the marker says how it went. Nothing is asked of the server for
`denied` or an error: the join page already knows, and the student needs
to read the outcome before anything else happens. `ok` goes straight into
creating the repository, which is what they were trying to do before the
join got in the way; a second click would only be the same request.
-}
onGithubJoinReturn : AssignmentSlug -> GithubJoinResult -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
onGithubJoinReturn slug result state =
    if not (usesFlow slug state) then
        ( state, [] )

    else
        case result of
            JoinOk ->
                onCreateRepository slug state

            JoinDenied ->
                ( setProgress slug
                    (Blocked
                        { status = { state = NeedsOrgJoin, repoUrl = Nothing, joinUrl = Just (githubJoinUrl slug) }
                        , notBefore = Nothing
                        , joinCancelled = True
                        }
                    )
                    state
                , []
                )

            JoinError code ->
                ( setProgress slug
                    (Failed
                        { error =
                            { code = code
                            , retryable = List.member code retryableJoinErrors
                            , httpStatus = 0
                            , retryAfterSeconds = Nothing
                            }
                        , notBefore = Nothing
                        }
                    )
                    state
                , []
                )


{-| The join can fail in ways that pass (GitHub or the platform down, a
rate limit, a membership GitHub has not activated yet) and in ways that do
not (the authorization refused, the GitHub account already claimed or
locked, the app misconfigured), which the teaching staff have to look at.
-}
retryableJoinErrors : List String
retryableJoinErrors =
    [ "github_unavailable", "github_rate_limited", "platform_unavailable", "membership_not_active" ]


{-| Record a failure. A rate limit (429) is the one failure with a clock on
it: the buttons stay off until `Retry-After` is up. When it hit the "Try
again" under a prerequisite message, the prerequisite is what the student
still needs to read, so that message stays and only picks up the hold.
-}
fail : AssignmentSlug -> Posix -> RepositoryError -> RepositoryFlowState a -> RepositoryFlowState a
fail slug now error state =
    let
        hold =
            if error.httpStatus == 429 then
                Just (addSeconds (Maybe.withDefault 30 error.retryAfterSeconds) now)

            else
                Nothing
    in
    case ( Dict.get slug state.assignmentRepositories, hold ) of
        ( Just (Blocked blocked), Just _ ) ->
            setProgress slug (Blocked { blocked | notBefore = hold }) state

        _ ->
            setProgress slug (Failed { error = error, notBefore = hold }) state


create : AssignmentSlug -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
create slug state =
    let
        ( generation, newState ) =
            nextGeneration slug (setProgress slug Creating state)
    in
    ( newState, [ CreateRequest slug generation ] )


load : AssignmentSlug -> RepositoryFlowState a -> ( RepositoryFlowState a, List RepositoryRequest )
load slug state =
    let
        ( generation, newState ) =
            nextGeneration slug state
    in
    ( newState, [ LoadRequest slug generation ] )


nextGeneration : AssignmentSlug -> RepositoryFlowState a -> ( Int, RepositoryFlowState a )
nextGeneration slug state =
    let
        generation =
            1 + Maybe.withDefault 0 (Dict.get slug state.repositoryGenerations)
    in
    ( generation, { state | repositoryGenerations = Dict.insert slug generation state.repositoryGenerations } )


isCurrent : AssignmentSlug -> Int -> RepositoryFlowState a -> Bool
isCurrent slug generation state =
    Dict.get slug state.repositoryGenerations == Just generation


{-| The assignment on screen, if its copy is being waited on.
-}
activePolling : RepositoryFlowState a -> Maybe ( AssignmentSlug, PollingRepository )
activePolling state =
    case state.route of
        AssignmentDetailRoute slug ->
            case Dict.get slug state.assignmentRepositories of
                Just (Polling polling) ->
                    Just ( slug, polling )

                _ ->
                    Nothing

        _ ->
            Nothing


usesFlow : AssignmentSlug -> RepositoryFlowState a -> Bool
usesFlow slug state =
    case state.currentUser of
        RemoteData.Success user ->
            state.assignments
                |> RemoteData.withDefault []
                |> List.any (\assignment -> assignment.slug == slug && usesRepositoryFlow user assignment)

        _ ->
            False


{-| Whether a rate limit's hold is still on, by the model's clock. The
clock ticks every five seconds, so this errs by at most that; the view
turns the button off by the same clock.
-}
onHold : Maybe Posix -> RepositoryFlowState a -> Bool
onHold notBefore state =
    case state.current_date of
        Just now ->
            isBefore now notBefore

        Nothing ->
            False


setProgress : AssignmentSlug -> RepositoryProgress -> RepositoryFlowState a -> RepositoryFlowState a
setProgress slug progress state =
    { state | assignmentRepositories = Dict.insert slug progress state.assignmentRepositories }


millisBetween : Posix -> Posix -> Int
millisBetween from to =
    Time.posixToMillis to - Time.posixToMillis from


isBefore : Posix -> Maybe Posix -> Bool
isBefore now maybeLimit =
    case maybeLimit of
        Just limit ->
            Time.posixToMillis now < Time.posixToMillis limit

        Nothing ->
            False


addSeconds : Int -> Posix -> Posix
addSeconds seconds time =
    Time.millisToPosix (Time.posixToMillis time + seconds * 1000)
