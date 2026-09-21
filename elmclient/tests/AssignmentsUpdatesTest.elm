module AssignmentsUpdatesTest exposing (tests)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentDrafts
        , AssignmentFieldSubmissionInputs
        , AssignmentRepositories
        , AssignmentSubmission
        , BeginAndSubmitFailure(..)
        , GithubJoinResult(..)
        , PendingAssignmentFieldSubmissionRequests
        , RepositoryError
        , RepositoryGenerations
        , RepositoryProgress(..)
        , RepositoryState(..)
        , RepositoryStatus
        )
import Assignments.Updates
    exposing
        ( RepositoryRequest(..)
        , adoptDrafts
        , isPollingActiveRoute
        , onBeginAndSubmitResponse
        , onCreateRepository
        , onCreateRepositoryResponse
        , onEnterAssignment
        , onGithubJoinReturn
        , onLoadRepository
        , onLoadRepositoryResponse
        , onRepositoryPollTick
        , onSubmitAnswers
        , onSubmitResponse
        , onUpdateDraftInput
        , pollTimeoutMillis
        )
import Auth.Model exposing (CurrentUser)
import Dict
import Expect
import Http
import Models exposing (Route(..))
import RemoteData exposing (WebData)
import Test exposing (Test, describe, test)
import Time


{-| The create/poll flow for a template-backed assignment, as the model
sees it. Each step is a pure transition returning the requests it wants
sent, so the tests read like the sequence a student would go through.

Every fixture state has request number 1 current for the assignment, so
replies numbered 1 are taken and a transition that sends something bumps
the number to 2.

-}
tests : Test
tests =
    describe "Assignments.Updates"
        [ repositoryTests
        , answersTests
        , workspaceTests
        ]


{-| The two flows together, on one model, in the order the messages arrive
in `Update`: a draft is typed, the repository is created and comes back
ready, the refetch it asked for delivers the new submission, and Submit
must then send what was typed.
-}
workspaceTests : Test
workspaceTests =
    describe "a draft typed before the repository is created"
        [ test "is sent by the first Submit after the repository is ready" <|
            \_ ->
                workspace
                    |> onUpdateDraftInput slug "notes" "something profound"
                    |> onCreateRepository slug
                    |> Tuple.first
                    |> onCreateRepositoryResponse slug 1 (at 1000) (Ok ready)
                    |> Expect.all
                        [ Tuple.second >> Expect.equal [ RefetchSubmissions ]
                        , Tuple.first
                            >> adoptDrafts student [ submissionRow ]
                            >> onSubmitAnswers slug (Just submissionRow.id)
                            >> Tuple.second
                            >> Expect.equal (Just [ ( "notes", "something profound" ) ])
                        ]
        , test "the same when the copy had to be polled for" <|
            \_ ->
                workspace
                    |> onUpdateDraftInput slug "notes" "something profound"
                    |> onCreateRepository slug
                    |> Tuple.first
                    |> onCreateRepositoryResponse slug 1 (at 1000) (Ok copying)
                    |> Tuple.first
                    |> onRepositoryPollTick (at 4000)
                    |> Tuple.first
                    |> onLoadRepositoryResponse slug 2 (at 4500) (Ok ready)
                    |> Expect.all
                        [ Tuple.second >> Expect.equal [ RefetchSubmissions ]
                        , Tuple.first
                            >> adoptDrafts student [ submissionRow ]
                            >> onSubmitAnswers slug (Just submissionRow.id)
                            >> Tuple.second
                            >> Expect.equal (Just [ ( "notes", "something profound" ) ])
                        ]
        ]


repositoryTests : Test
repositoryTests =
    describe "repositories"
        [ describe "arriving at an assignment"
            [ test "a template assignment seen for the first time is checked" <|
                \_ ->
                    onEnterAssignment slug initial
                        |> Expect.equal ( withProgressGen 1 Checking, [ LoadRequest slug 1 ] )
            , test "an assignment without a template is left to the old flow" <|
                \_ ->
                    onEnterAssignment plainSlug initial
                        |> Expect.equal ( initial, [] )
            , test "staff are left to the old flow too" <|
                \_ ->
                    onEnterAssignment slug { initial | currentUser = RemoteData.Success faculty }
                        |> Expect.equal ( { initial | currentUser = RemoteData.Success faculty }, [] )
            , test "a state already known is re-checked without being thrown away" <|
                \_ ->
                    onEnterAssignment slug (withProgress (Done ready))
                        |> Expect.equal ( withProgressGen 2 (Done ready), [ LoadRequest slug 2 ] )
            , test "a create in flight is not disturbed" <|
                \_ ->
                    onEnterAssignment slug (withProgress Creating)
                        |> Expect.equal ( withProgress Creating, [] )
            , test "a copy left polling when the student went away is asked after again" <|
                \_ ->
                    onEnterAssignment slug (withProgress (polling 0))
                        |> Expect.equal ( withProgressGen 2 (pollingInFlight 0), [ LoadRequest slug 2 ] )
            ]
        , describe "the answer to that check"
            [ test "404 repository_not_started shows the create button" <|
                \_ ->
                    loaded (Err notStarted) (withProgress Checking)
                        |> Expect.equal ( withProgress NotStarted, [] )
            , test "ready is done, and the submissions are refetched for the recorded URL" <|
                \_ ->
                    loaded (Ok ready) (withProgress Checking)
                        |> Expect.equal ( withProgress (Done ready), [ RefetchSubmissions ] )
            , test "copying starts polling from now" <|
                \_ ->
                    loaded (Ok copying) (withProgress Checking)
                        |> Expect.equal ( withProgress (polling 0), [] )
            , test "needs_org_join is blocked" <|
                \_ ->
                    loaded (Ok needsOrgJoin) (withProgress Checking)
                        |> Expect.equal ( withProgress (blocked needsOrgJoin), [] )
            , test "provisioning_interrupted is a failure the view can offer to resume" <|
                \_ ->
                    loaded (Err interrupted) (withProgress Checking)
                        |> Expect.equal ( withProgress (failed interrupted), [] )
            , test "an expired session is a failure with no retry" <|
                \_ ->
                    loaded (Err sessionExpired) (withProgress Checking)
                        |> Expect.equal ( withProgress (failed sessionExpired), [] )
            ]
        , describe "creating"
            [ test "a click sends the create and disables the button" <|
                \_ ->
                    onCreateRepository slug (withProgress NotStarted)
                        |> Expect.equal ( withProgressGen 2 Creating, [ CreateRequest slug 2 ] )
            , test "a second click while it is out sends nothing" <|
                \_ ->
                    onCreateRepository slug (withProgress Creating)
                        |> Expect.equal ( withProgress Creating, [] )
            , test "a click while a copy is being polled sends nothing" <|
                \_ ->
                    onCreateRepository slug (withProgress (polling 0))
                        |> Expect.equal ( withProgress (polling 0), [] )
            , test "resume after an interruption is a create" <|
                \_ ->
                    onCreateRepository slug (withProgress (failed interrupted))
                        |> Expect.equal ( withProgressGen 2 Creating, [ CreateRequest slug 2 ] )
            , test "ready straight away is done, with the submissions refetched" <|
                \_ ->
                    created (Ok ready) (withProgress Creating)
                        |> Expect.equal ( withProgress (Done ready), [ RefetchSubmissions ] )
            , test "copying starts polling" <|
                \_ ->
                    created (Ok copying) (withProgress Creating)
                        |> Expect.equal ( withProgress (polling 0), [] )
            , test "needs_github_link is blocked" <|
                \_ ->
                    created (Ok needsGithubLink) (withProgress Creating)
                        |> Expect.equal ( withProgress (blocked needsGithubLink), [] )
            , test "a refusal is a failure" <|
                \_ ->
                    created (Err nameTaken) (withProgress Creating)
                        |> Expect.equal ( withProgress (failed nameTaken), [] )
            , test "an answer arriving when nothing is being created is ignored" <|
                \_ ->
                    created (Ok ready) (withProgress NotStarted)
                        |> Expect.equal ( withProgress NotStarted, [] )
            ]

        -- A status check goes out on arrival. If the student clicks "Create"
        -- before it answers, its answer is about a world that no longer
        -- exists: a 404 from it must not put the create button back, and a
        -- stale `copying` or `needs_*` must not undo a `ready`.
        , describe "a check that was out when the create was sent"
            [ test "the create supersedes it" <|
                \_ ->
                    onCreateRepository slug (withProgress Checking)
                        |> Expect.equal ( withProgressGen 2 Creating, [ CreateRequest slug 2 ] )
            , test "its 404 arriving afterwards is dropped" <|
                \_ ->
                    onCreateRepository slug (withProgress Checking)
                        |> Tuple.first
                        |> onLoadRepositoryResponse slug 1 (at 500) (Err notStarted)
                        |> Expect.equal ( withProgressGen 2 Creating, [] )
            , test "and the create's own answer is still taken" <|
                \_ ->
                    onCreateRepository slug (withProgress Checking)
                        |> Tuple.first
                        |> onLoadRepositoryResponse slug 1 (at 500) (Err notStarted)
                        |> Tuple.first
                        |> onCreateRepositoryResponse slug 2 (at 1000) (Ok ready)
                        |> Expect.equal ( withProgressGen 2 (Done ready), [ RefetchSubmissions ] )
            , test "its stale copying cannot demote a finished repository" <|
                \_ ->
                    onLoadRepositoryResponse slug 1 (at 1500) (Ok copying) (withProgressGen 2 (Done ready))
                        |> Expect.equal ( withProgressGen 2 (Done ready), [] )
            , test "nor can its stale needs_org_join" <|
                \_ ->
                    onLoadRepositoryResponse slug 1 (at 1500) (Ok needsOrgJoin) (withProgressGen 2 (Done ready))
                        |> Expect.equal ( withProgressGen 2 (Done ready), [] )
            ]
        , describe "polling"
            [ test "the poll timer runs while the assignment on screen waits on a copy" <|
                \_ ->
                    isPollingActiveRoute (withProgress (polling 0))
                        |> Expect.equal True
            , test "and not once the copy is done" <|
                \_ ->
                    isPollingActiveRoute (withProgress (Done ready))
                        |> Expect.equal False
            , test "a tick sends one status request" <|
                \_ ->
                    onRepositoryPollTick (at 3000) (withProgress (polling 0))
                        |> Expect.equal ( withProgressGen 2 (pollingInFlight 0), [ LoadRequest slug 2 ] )
            , test "the next tick does not send another while it is out" <|
                \_ ->
                    onRepositoryPollTick (at 6000) (withProgress (pollingInFlight 0))
                        |> Expect.equal ( withProgress (pollingInFlight 0), [] )
            , test "still copying keeps polling, from the original start" <|
                \_ ->
                    loadedAt 6000 (Ok copying) (withProgress (pollingInFlight 0))
                        |> Expect.equal ( withProgress (polling 0), [] )
            , test "ready ends it, with the submissions refetched" <|
                \_ ->
                    loadedAt 6000 (Ok ready) (withProgress (pollingInFlight 0))
                        |> Expect.equal ( withProgress (Done ready), [ RefetchSubmissions ] )
            , test "a rate limit holds the next poll off by Retry-After" <|
                \_ ->
                    loadedAt 6000 (Err rateLimited) (withProgress (pollingInFlight 0))
                        |> Expect.equal ( withProgress (pollingNotBefore 0 (6000 + 17000)), [] )
            , test "a tick during the hold sends nothing" <|
                \_ ->
                    onRepositoryPollTick (at 9000) (withProgress (pollingNotBefore 0 23000))
                        |> Expect.equal ( withProgress (pollingNotBefore 0 23000), [] )
            , test "a tick after the hold polls again" <|
                \_ ->
                    onRepositoryPollTick (at 24000) (withProgress (pollingNotBefore 0 23000))
                        |> Expect.equal ( withProgressGen 2 (Polling { since = at 0, last = copying, inFlight = True, notBefore = Just (at 23000) }), [ LoadRequest slug 2 ] )
            , test "a GitHub hiccup keeps polling rather than giving up" <|
                \_ ->
                    loadedAt 6000 (Err githubUnavailable) (withProgress (pollingInFlight 0))
                        |> Expect.equal ( withProgress (polling 0), [] )
            , test "a refusal ends it" <|
                \_ ->
                    loadedAt 6000 (Err nameTaken) (withProgress (pollingInFlight 0))
                        |> Expect.equal ( withProgress (failed nameTaken), [] )
            , test "after two minutes it gives up, keeping the last status" <|
                \_ ->
                    onRepositoryPollTick (at pollTimeoutMillis) (withProgress (polling 0))
                        |> Expect.equal ( withProgress (PollTimedOut copying), [] )
            , test "just short of two minutes it polls on" <|
                \_ ->
                    onRepositoryPollTick (at (pollTimeoutMillis - 1)) (withProgress (polling 0))
                        |> Expect.equal ( withProgressGen 2 (pollingInFlight 0), [ LoadRequest slug 2 ] )
            , test "a late answer to the poll that timed out does not restart polling" <|
                \_ ->
                    loadedAt pollTimeoutMillis (Ok copying) (withProgress (PollTimedOut copying))
                        |> Expect.equal ( withProgress (PollTimedOut copying), [] )
            , test "but a late ready is still ready" <|
                \_ ->
                    loadedAt pollTimeoutMillis (Ok ready) (withProgress (PollTimedOut copying))
                        |> Expect.equal ( withProgress (Done ready), [ RefetchSubmissions ] )
            , test "\"Check again\" asks once more" <|
                \_ ->
                    onLoadRepository slug (withProgress (PollTimedOut copying))
                        |> Expect.equal ( withProgressGen 2 Checking, [ LoadRequest slug 2 ] )
            , test "and still copying then starts a fresh two minutes" <|
                \_ ->
                    loadedAt 200000 (Ok copying) (withProgress Checking)
                        |> Expect.equal ( withProgress (polling 200000), [] )
            , test "an assignment not being waited on is left alone by the timer" <|
                \_ ->
                    onRepositoryPollTick (at 3000) (withProgress NotStarted)
                        |> Expect.equal ( withProgress NotStarted, [] )
            ]

        -- Only the page on screen polls. A copy left behind stays known, so
        -- the link is there on return, but nothing asks after it meanwhile.
        , describe "leaving the page while a copy is waited on"
            [ test "stops the timer" <|
                \_ ->
                    isPollingActiveRoute (away (withProgress (polling 0)))
                        |> Expect.equal False
            , test "and a tick that slips through sends nothing" <|
                \_ ->
                    onRepositoryPollTick (at 3000) (away (withProgress (polling 0)))
                        |> Expect.equal ( away (withProgress (polling 0)), [] )
            , test "keeps the copy as it was" <|
                \_ ->
                    onEnterAssignment plainSlug (away (withProgress (polling 0)))
                        |> Expect.equal ( away (withProgress (polling 0)), [] )
            , test "a ready that arrives meanwhile is recorded but refetches nothing" <|
                \_ ->
                    loadedAt 6000 (Ok ready) (away (withProgress (pollingInFlight 0)))
                        |> Expect.equal ( away (withProgress (Done ready)), [] )
            , test "coming back asks again" <|
                \_ ->
                    onEnterAssignment slug (withProgress (polling 0))
                        |> Expect.equal ( withProgressGen 2 (pollingInFlight 0), [ LoadRequest slug 2 ] )
            , test "and a ready on return refetches even if it was already known" <|
                \_ ->
                    loadedAt 9000 (Ok ready) (withProgress (Done ready))
                        |> Expect.equal ( withProgress (Done ready), [ RefetchSubmissions ] )
            ]

        -- Back from the GitHub organization join (issue #399), with the
        -- marker authapp put in the URL.
        , describe "returning from the GitHub join"
            [ test "ok goes straight into creating the repository" <|
                \_ ->
                    onGithubJoinReturn slug JoinOk (withProgress (blocked needsOrgJoin))
                        |> Expect.equal ( withProgressGen 2 Creating, [ CreateRequest slug 2 ] )
            , test "ok on a first visit this session creates too" <|
                \_ ->
                    onGithubJoinReturn slug JoinOk initial
                        |> Expect.equal ( withProgressGen 1 Creating, [ CreateRequest slug 1 ] )
            , test "ok while a create is already out does not send another" <|
                \_ ->
                    onGithubJoinReturn slug JoinOk (withProgress Creating)
                        |> Expect.equal ( withProgress Creating, [] )
            , test "denied shows the join again, saying it was cancelled" <|
                \_ ->
                    onGithubJoinReturn slug JoinDenied initial
                        |> Expect.equal
                            ( { initial
                                | assignmentRepositories =
                                    Dict.singleton slug
                                        (Blocked
                                            { status = { state = NeedsOrgJoin, repoUrl = Nothing, joinUrl = Just "/auth/github/join?assignment_slug=project-1" }
                                            , notBefore = Nothing
                                            , joinCancelled = True
                                            }
                                        )
                              }
                            , []
                            )
            , test "a passing error is a retryable failure" <|
                \_ ->
                    onGithubJoinReturn slug (JoinError "github_rate_limited") initial
                        |> Expect.equal ( { initial | assignmentRepositories = Dict.singleton slug (failed (joinError "github_rate_limited" True)) }, [] )
            , test "one for the teaching staff is not" <|
                \_ ->
                    onGithubJoinReturn slug (JoinError "github_identity_taken") initial
                        |> Expect.equal ( { initial | assignmentRepositories = Dict.singleton slug (failed (joinError "github_identity_taken" False)) }, [] )
            , test "staff are not sent anywhere by a marker" <|
                \_ ->
                    onGithubJoinReturn slug JoinOk { initial | currentUser = RemoteData.Success faculty }
                        |> Expect.equal ( { initial | currentUser = RemoteData.Success faculty }, [] )
            ]
        , describe "a failed create"
            [ test "\"Try again\" asks where things stand rather than creating blindly" <|
                \_ ->
                    onLoadRepository slug (withProgress (failed githubUnavailable))
                        |> Expect.equal ( withProgressGen 2 Checking, [ LoadRequest slug 2 ] )
            , test "and the create button comes back if nothing landed" <|
                \_ ->
                    loaded (Err notStarted) (withProgress Checking)
                        |> Expect.equal ( withProgress NotStarted, [] )
            , test "a second \"Try again\" while the first is out sends nothing" <|
                \_ ->
                    onLoadRepository slug (withProgress Checking)
                        |> Expect.equal ( withProgress Checking, [] )
            ]

        -- A 429 has a clock on it. Whatever it answered, the buttons stay
        -- off until Retry-After is up, and clicks meanwhile go nowhere.
        , describe "a rate limit"
            [ test "on the create holds the failure until Retry-After is up" <|
                \_ ->
                    onCreateRepositoryResponse slug 1 (at 1000) (Err rateLimited) (withProgress Creating)
                        |> Expect.equal ( withProgress (heldFailure 18000), [] )
            , test "on a manual check holds the failure too" <|
                \_ ->
                    onLoadRepositoryResponse slug 1 (at 1000) (Err rateLimited) (withProgress Checking)
                        |> Expect.equal ( withProgress (heldFailure 18000), [] )
            , test "on the re-check under a prerequisite keeps the prerequisite on screen" <|
                \_ ->
                    onLoadRepositoryResponse slug 1 (at 1000) (Err rateLimited) (withProgress (blocked needsOrgJoin))
                        |> Expect.equal ( withProgress (heldBlock 18000), [] )
            , test "\"Try again\" before the hold is up sends nothing" <|
                \_ ->
                    onLoadRepository slug (clockAt 10000 (withProgress (heldFailure 18000)))
                        |> Expect.equal ( clockAt 10000 (withProgress (heldFailure 18000)), [] )
            , test "\"Resume\" before the hold is up sends nothing" <|
                \_ ->
                    onCreateRepository slug (clockAt 10000 (withProgress (heldFailure 18000)))
                        |> Expect.equal ( clockAt 10000 (withProgress (heldFailure 18000)), [] )
            , test "a prerequisite's \"Try again\" before the hold is up sends nothing" <|
                \_ ->
                    onCreateRepository slug (clockAt 10000 (withProgress (heldBlock 18000)))
                        |> Expect.equal ( clockAt 10000 (withProgress (heldBlock 18000)), [] )
            , test "\"Try again\" once the hold is up goes out" <|
                \_ ->
                    onLoadRepository slug (clockAt 18000 (withProgress (heldFailure 18000)))
                        |> Tuple.second
                        |> Expect.equal [ LoadRequest slug 2 ]
            , test "a prerequisite's \"Try again\" once the hold is up goes out" <|
                \_ ->
                    onCreateRepository slug (clockAt 18000 (withProgress (heldBlock 18000)))
                        |> Tuple.second
                        |> Expect.equal [ CreateRequest slug 2 ]
            ]
        ]


{-| Answers typed for an assignment nobody has begun are drafts, keyed by
the assignment. A submission can appear without the student submitting
(creating the repository begins the assignment), and the drafts must
follow it or the next Submit sends nothing.
-}
answersTests : Test
answersTests =
    describe "answers"
        [ describe "drafts"
            [ test "a keystroke is held under the assignment" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> .assignmentDrafts
                        |> Expect.equal (Dict.singleton slug (Dict.singleton "notes" "hello"))
            , test "two unbegun assignments keep separate drafts" <|
                \_ ->
                    noAnswers
                        |> typed slug "notes" "hello"
                        |> typed plainSlug "notes" "other"
                        |> .assignmentDrafts
                        |> Expect.equal (Dict.fromList [ ( slug, Dict.singleton "notes" "hello" ), ( plainSlug, Dict.singleton "notes" "other" ) ])
            , test "Submit before any submission sends the draft" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> onSubmitAnswers slug Nothing
                        |> Tuple.second
                        |> Expect.equal (Just [ ( "notes", "hello" ) ])
            , test "the draft moves under the submission once it turns up" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> adoptDrafts student [ submissionRow ]
                        |> Expect.all
                            [ .assignmentFieldSubmissionInputs >> Expect.equal (Dict.singleton ( submissionRow.id, "notes" ) "hello")
                            , .assignmentDrafts >> Expect.equal Dict.empty
                            ]
            , test "so that Submit then sends what was typed" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> adoptDrafts student [ submissionRow ]
                        |> onSubmitAnswers slug (Just submissionRow.id)
                        |> Tuple.second
                        |> Expect.equal (Just [ ( "notes", "hello" ) ])
            , test "a draft for an assignment still unbegun stays where it is" <|
                \_ ->
                    noAnswers
                        |> typed slug "notes" "hello"
                        |> typed plainSlug "notes" "other"
                        |> adoptDrafts student [ submissionRow ]
                        |> .assignmentDrafts
                        |> Expect.equal (Dict.singleton plainSlug (Dict.singleton "notes" "other"))
            , test "someone else's submission adopts nothing" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> adoptDrafts student [ { submissionRow | user_id = Just 99 } ]
                        |> .assignmentDrafts
                        |> Expect.equal (Dict.singleton slug (Dict.singleton "notes" "hello"))
            , test "what was typed since under the real id wins" <|
                \_ ->
                    { noAnswers | assignmentFieldSubmissionInputs = Dict.singleton ( submissionRow.id, "notes" ) "newer" }
                        |> typed slug "notes" "older"
                        |> adoptDrafts student [ submissionRow ]
                        |> .assignmentFieldSubmissionInputs
                        |> Expect.equal (Dict.singleton ( submissionRow.id, "notes" ) "newer")
            ]
        , describe "begin-then-submit"
            [ test "success drops the draft and refetches" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> onSubmitAnswers slug Nothing
                        |> Tuple.first
                        |> onBeginAndSubmitResponse slug (Ok [])
                        |> Expect.all
                            [ Tuple.second >> Expect.equal True
                            , Tuple.first >> .assignmentDrafts >> Expect.equal Dict.empty
                            , Tuple.first >> pendingFor slug >> Expect.equal Nothing
                            ]
            , test "a row created but answers not saved: refetch, keep the draft, say so" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> onSubmitAnswers slug Nothing
                        |> Tuple.first
                        |> onBeginAndSubmitResponse slug (Err (SendFailed Http.NetworkError))
                        |> Expect.all
                            [ Tuple.second >> Expect.equal True
                            , Tuple.first >> .assignmentDrafts >> Expect.equal (Dict.singleton slug (Dict.singleton "notes" "hello"))
                            , Tuple.first >> pendingFor slug >> Expect.equal (Just (RemoteData.Failure Http.NetworkError))
                            ]
            , test "and once the row is on the page the draft is under its id for the ordinary path" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> onSubmitAnswers slug Nothing
                        |> Tuple.first
                        |> onBeginAndSubmitResponse slug (Err (SendFailed Http.NetworkError))
                        |> Tuple.first
                        |> adoptDrafts student [ submissionRow ]
                        |> onSubmitAnswers slug (Just submissionRow.id)
                        |> Tuple.second
                        |> Expect.equal (Just [ ( "notes", "hello" ) ])
            , test "no row created: keep the draft, say so, nothing to refetch" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> onSubmitAnswers slug Nothing
                        |> Tuple.first
                        |> onBeginAndSubmitResponse slug (Err (BeginFailed (Http.BadStatus 500)))
                        |> Expect.all
                            [ Tuple.second >> Expect.equal False
                            , Tuple.first >> .assignmentDrafts >> Expect.equal (Dict.singleton slug (Dict.singleton "notes" "hello"))
                            , Tuple.first >> pendingFor slug >> Expect.equal (Just (RemoteData.Failure (Http.BadStatus 500)))
                            ]
            , test "a second Submit while the first is out sends nothing" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> onSubmitAnswers slug Nothing
                        |> Tuple.first
                        |> onSubmitAnswers slug Nothing
                        |> Tuple.second
                        |> Expect.equal Nothing
            , test "a Submit after a failure goes out again" <|
                \_ ->
                    typed slug "notes" "hello" noAnswers
                        |> onSubmitAnswers slug Nothing
                        |> Tuple.first
                        |> onBeginAndSubmitResponse slug (Err (BeginFailed Http.NetworkError))
                        |> Tuple.first
                        |> onSubmitAnswers slug Nothing
                        |> Tuple.second
                        |> Expect.equal (Just [ ( "notes", "hello" ) ])
            ]
        , describe "an ordinary submit"
            [ test "a second Submit while the first is out sends nothing" <|
                \_ ->
                    { noAnswers | assignmentFieldSubmissionInputs = Dict.singleton ( submissionRow.id, "notes" ) "hello" }
                        |> onSubmitAnswers slug (Just submissionRow.id)
                        |> Tuple.first
                        |> onSubmitAnswers slug (Just submissionRow.id)
                        |> Tuple.second
                        |> Expect.equal Nothing
            , test "a failure is recorded so the form can say so" <|
                \_ ->
                    { noAnswers | assignmentFieldSubmissionInputs = Dict.singleton ( submissionRow.id, "notes" ) "hello" }
                        |> onSubmitAnswers slug (Just submissionRow.id)
                        |> Tuple.first
                        |> onSubmitResponse slug (RemoteData.Failure Http.NetworkError)
                        |> Expect.all
                            [ Tuple.second >> Expect.equal False
                            , Tuple.first >> pendingFor slug >> Expect.equal (Just (RemoteData.Failure Http.NetworkError))
                            ]
            , test "success clears the pending entry and refetches" <|
                \_ ->
                    { noAnswers | assignmentFieldSubmissionInputs = Dict.singleton ( submissionRow.id, "notes" ) "hello" }
                        |> onSubmitAnswers slug (Just submissionRow.id)
                        |> Tuple.first
                        |> onSubmitResponse slug (RemoteData.Success [])
                        |> Expect.all
                            [ Tuple.second >> Expect.equal True
                            , Tuple.first >> pendingFor slug >> Expect.equal Nothing
                            ]
            ]
        ]



-- Fixtures and helpers


{-| Both slices at once, as `Models.Model` has them.
-}
type alias Workspace =
    { assignments : WebData (List Assignment)
    , assignmentRepositories : AssignmentRepositories
    , repositoryGenerations : RepositoryGenerations
    , currentUser : WebData CurrentUser
    , current_date : Maybe Time.Posix
    , route : Route
    , assignmentFieldSubmissionInputs : AssignmentFieldSubmissionInputs
    , assignmentDrafts : AssignmentDrafts
    , pendingAssignmentFieldSubmissionRequests : PendingAssignmentFieldSubmissionRequests
    }


workspace : Workspace
workspace =
    { assignments = RemoteData.Success [ templateAssignment, plainAssignment ]
    , assignmentRepositories = Dict.singleton slug NotStarted
    , repositoryGenerations = Dict.empty
    , currentUser = RemoteData.Success student
    , current_date = Nothing
    , route = AssignmentDetailRoute slug
    , assignmentFieldSubmissionInputs = Dict.empty
    , assignmentDrafts = Dict.empty
    , pendingAssignmentFieldSubmissionRequests = Dict.empty
    }


type alias Answers =
    { assignmentFieldSubmissionInputs : AssignmentFieldSubmissionInputs
    , assignmentDrafts : AssignmentDrafts
    , pendingAssignmentFieldSubmissionRequests : PendingAssignmentFieldSubmissionRequests
    }


noAnswers : Answers
noAnswers =
    { assignmentFieldSubmissionInputs = Dict.empty
    , assignmentDrafts = Dict.empty
    , pendingAssignmentFieldSubmissionRequests = Dict.empty
    }


typed : String -> String -> String -> Answers -> Answers
typed assignmentSlug fieldSlug value answers =
    onUpdateDraftInput assignmentSlug fieldSlug value answers


pendingFor : String -> Answers -> Maybe (WebData (List AssignmentSubmission))
pendingFor assignmentSlug answers =
    Dict.get assignmentSlug answers.pendingAssignmentFieldSubmissionRequests


{-| The student's submission to the template assignment, as the refetch
after `ready` brings it back.
-}
submissionRow : AssignmentSubmission
submissionRow =
    { id = 7
    , assignment_slug = slug
    , is_team = False
    , user_id = Just student.id
    , team_nickname = Nothing
    , submitter_user_id = student.id
    , created_at = at 0
    , updated_at = at 0
    , fields = []
    }


type alias State =
    { assignments : WebData (List Assignment)
    , assignmentRepositories : AssignmentRepositories
    , repositoryGenerations : RepositoryGenerations
    , currentUser : WebData CurrentUser
    , current_date : Maybe Time.Posix
    , route : Route
    }


slug : String
slug =
    "project-1"


plainSlug : String
plainSlug =
    "reading-response"


{-| On the template assignment's page, nothing known about its repository.
-}
initial : State
initial =
    { assignments = RemoteData.Success [ templateAssignment, plainAssignment ]
    , assignmentRepositories = Dict.empty
    , repositoryGenerations = Dict.empty
    , currentUser = RemoteData.Success student
    , current_date = Nothing
    , route = AssignmentDetailRoute slug
    }


withProgress : RepositoryProgress -> State
withProgress =
    withProgressGen 1


withProgressGen : Int -> RepositoryProgress -> State
withProgressGen generation p =
    { initial
        | assignmentRepositories = Dict.singleton slug p
        , repositoryGenerations = Dict.singleton slug generation
    }


{-| The same, but the student has gone to the assignments list.
-}
away : State -> State
away state =
    { state | route = AssignmentListRoute }


clockAt : Int -> State -> State
clockAt millis state =
    { state | current_date = Just (at millis) }


polling : Int -> RepositoryProgress
polling sinceMillis =
    Polling { since = at sinceMillis, last = copying, inFlight = False, notBefore = Nothing }


pollingInFlight : Int -> RepositoryProgress
pollingInFlight sinceMillis =
    Polling { since = at sinceMillis, last = copying, inFlight = True, notBefore = Nothing }


pollingNotBefore : Int -> Int -> RepositoryProgress
pollingNotBefore sinceMillis notBeforeMillis =
    Polling { since = at sinceMillis, last = copying, inFlight = False, notBefore = Just (at notBeforeMillis) }


blocked : RepositoryStatus -> RepositoryProgress
blocked status =
    Blocked { status = status, notBefore = Nothing, joinCancelled = False }


failed : RepositoryError -> RepositoryProgress
failed error =
    Failed { error = error, notBefore = Nothing }


heldFailure : Int -> RepositoryProgress
heldFailure notBeforeMillis =
    Failed { error = rateLimited, notBefore = Just (at notBeforeMillis) }


heldBlock : Int -> RepositoryProgress
heldBlock notBeforeMillis =
    Blocked { status = needsOrgJoin, notBefore = Just (at notBeforeMillis), joinCancelled = False }


loaded : Result RepositoryError RepositoryStatus -> State -> ( State, List RepositoryRequest )
loaded =
    loadedAt 0


loadedAt : Int -> Result RepositoryError RepositoryStatus -> State -> ( State, List RepositoryRequest )
loadedAt nowMillis result state =
    onLoadRepositoryResponse slug 1 (at nowMillis) result state


created : Result RepositoryError RepositoryStatus -> State -> ( State, List RepositoryRequest )
created result state =
    onCreateRepositoryResponse slug 1 (at 0) result state


at : Int -> Time.Posix
at =
    Time.millisToPosix


ready : RepositoryStatus
ready =
    { state = Ready, repoUrl = Just "https://github.com/org/project-1-abc123", joinUrl = Nothing }


copying : RepositoryStatus
copying =
    { ready | state = Copying }


needsOrgJoin : RepositoryStatus
needsOrgJoin =
    { state = NeedsOrgJoin, repoUrl = Nothing, joinUrl = Just "https://github.com/orgs/org/invitation" }


needsGithubLink : RepositoryStatus
needsGithubLink =
    { state = NeedsGithubLink, repoUrl = Nothing, joinUrl = Nothing }


notStarted : RepositoryError
notStarted =
    { code = "repository_not_started", retryable = False, httpStatus = 404, retryAfterSeconds = Nothing }


interrupted : RepositoryError
interrupted =
    { code = "provisioning_interrupted", retryable = True, httpStatus = 409, retryAfterSeconds = Nothing }


nameTaken : RepositoryError
nameTaken =
    { code = "name_taken", retryable = False, httpStatus = 409, retryAfterSeconds = Nothing }


githubUnavailable : RepositoryError
githubUnavailable =
    { code = "github_unavailable", retryable = True, httpStatus = 502, retryAfterSeconds = Nothing }


rateLimited : RepositoryError
rateLimited =
    { code = "rate_limited", retryable = True, httpStatus = 429, retryAfterSeconds = Just 17 }


joinError : String -> Bool -> RepositoryError
joinError code retryable =
    { code = code, retryable = retryable, httpStatus = 0, retryAfterSeconds = Nothing }


sessionExpired : RepositoryError
sessionExpired =
    { code = "session_expired", retryable = False, httpStatus = 401, retryAfterSeconds = Nothing }


student : CurrentUser
student =
    { id = 42
    , netid = "abc123"
    , jwt = "jwt"
    , role = "student"
    , nickname = "student"
    , team_nickname = Just "team-a"
    }


faculty : CurrentUser
faculty =
    { student | id = 1, netid = "prof1", role = "faculty", nickname = "prof" }


templateAssignment : Assignment
templateAssignment =
    { plainAssignment
        | slug = slug
        , repository_template_provider = Just "github"
        , repository_template_full_name = Just "org/project-1-template"
        , repository_url_field_slug = Just "repository_url"
    }


plainAssignment : Assignment
plainAssignment =
    { slug = plainSlug
    , points_possible = 10
    , is_draft = False
    , is_markdown = True
    , is_team = False
    , is_open = True
    , title = "Reading response"
    , body = "Body"
    , closed_at = at 2000
    , fields = []
    , repository_template_provider = Nothing
    , repository_template_full_name = Nothing
    , repository_url_field_slug = Nothing
    }
