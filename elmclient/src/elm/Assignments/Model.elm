module Assignments.Model exposing
    ( Assignment
    , AssignmentField
    , AssignmentFieldSubmission
    , AssignmentFieldSubmissionInputs
    , AssignmentGrade
    , AssignmentGradeDistribution
    , AssignmentGradeException
    , AssignmentSlug
    , AssignmentSubmission
    , AssignmentSubmissionAction(..)
    , AssignmentRepositories
    , BlockedRepository
    , FailedRepository
    , GithubJoinResult(..)
    , NotSubmissibleReason(..)
    , PendingAssignmentFieldSubmissionRequests
    , PendingBeginAssignments
    , PollingRepository
    , RepositoryError
    , RepositoryGenerations
    , RepositoryProgress(..)
    , RepositoryState(..)
    , RepositoryStatus
    , SubmissibleState(..)
    , assignmentFieldSubmissionsDecoder
    , assignmentGradeDistributionsDecoder
    , assignmentGradeExceptionsDecoder
    , assignmentGradesDecoder
    , assignmentSubmissionDecoder
    , assignmentSubmissionsDecoder
    , assignmentsDecoder
    , assignmentSubmissionAction
    , hasRepositoryTemplate
    , isSubmissible
    , notSubmissibleMessage
    , repositoryErrorDecoder
    , repositoryStatusDecoder
    , submissionBelongsToUser
    , usesRepositoryFlow
    , valuesForSubmissionID
    , githubJoinResult
    )

import Auth.Model exposing (CurrentUser)
import Common.Comparisons exposing (dateIsLessThan)
import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Decode.Extra
import Json.Decode.Pipeline exposing (hardcoded, optional, required)
import RemoteData exposing (WebData)
import Time exposing (Posix)


type alias AssignmentSlug =
    String


type alias Assignment =
    { slug : String
    , points_possible : Int
    , is_draft : Bool
    , is_markdown : Bool
    , is_team : Bool
    , is_open : Bool
    , title : String
    , body : String
    , closed_at : Posix
    , fields : List AssignmentField

    -- Set together or not at all: the GitHub template this assignment's
    -- repositories are generated from, and the submission field the
    -- resulting repository URL is recorded in. An assignment without them
    -- keeps the plain "Begin assignment" flow.
    , repository_template_provider : Maybe String
    , repository_template_full_name : Maybe String
    , repository_url_field_slug : Maybe String
    }


{-| Whether this assignment hands out repositories from a template, and so
gets the create/poll flow instead of the "Begin assignment" button.
-}
hasRepositoryTemplate : Assignment -> Bool
hasRepositoryTemplate assignment =
    case ( assignment.repository_template_provider, assignment.repository_template_full_name, assignment.repository_url_field_slug ) of
        ( Just _, Just _, Just _ ) ->
            True

        _ ->
            False


{-| Whether this person gets the create/poll flow for this assignment.
Only students do: the server refuses anyone else, and staff looking at an
assignment want the page as students who have not started see it, not a
refusal aimed at themselves.
-}
usesRepositoryFlow : CurrentUser -> Assignment -> Bool
usesRepositoryFlow user assignment =
    user.role == "student" && hasRepositoryTemplate assignment


type alias AssignmentField =
    { slug : String
    , assignment_slug : String
    , label : String
    , help : String
    , placeholder : String
    , example : String
    , pattern : String
    , is_url : Bool
    , is_multiline : Bool
    , display_order : Int
    , created_at : Posix
    , updated_at : Posix
    }


type alias AssignmentSubmission =
    { id : Int
    , assignment_slug : String
    , is_team : Bool
    , user_id : Maybe Int
    , team_nickname : Maybe String
    , submitter_user_id : Int
    , created_at : Posix
    , updated_at : Posix
    , fields : List AssignmentFieldSubmission
    }


type alias AssignmentFieldSubmission =
    { assignment_submission_id : Int
    , assignment_field_slug : String
    , assignment_slug : String
    , body : String
    , submitter_user_id : Int
    , created_at : Posix
    , updated_at : Posix
    }


valuesForSubmissionID : Int -> AssignmentFieldSubmissionInputs -> List ( String, String )
valuesForSubmissionID submissionID afsi =
    -- Get key, value tuples out of the afsi where the
    -- submission id matches
    afsi
        |> Dict.filter (\k -> \_ -> Tuple.first k == submissionID)
        |> Dict.toList
        |> List.map (\( ( _, b ), c ) -> ( b, c ))


type alias AssignmentFieldSubmissionInputs =
    Dict ( Int, String ) String


type alias PendingAssignmentFieldSubmissionRequests =
    Dict AssignmentSlug (WebData (List AssignmentSubmission))


type alias PendingBeginAssignments =
    Dict AssignmentSlug (WebData AssignmentSubmission)


assignmentsDecoder : Decode.Decoder (List Assignment)
assignmentsDecoder =
    Decode.list assignmentDecoder


emptyAssignmentFieldSubmissionList : List AssignmentFieldSubmission
emptyAssignmentFieldSubmissionList =
    []


assignmentDecoder : Decode.Decoder Assignment
assignmentDecoder =
    Decode.succeed Assignment
        |> required "slug" Decode.string
        |> required "points_possible" Decode.int
        |> required "is_draft" Decode.bool
        |> required "is_markdown" Decode.bool
        |> required "is_team" Decode.bool
        |> required "is_open" Decode.bool
        |> required "title" Decode.string
        |> required "body" Decode.string
        |> required "closed_at" Json.Decode.Extra.datetime
        |> required "fields" assignmentFieldsDecoder
        |> optional "repository_template_provider" (Decode.nullable Decode.string) Nothing
        |> optional "repository_template_full_name" (Decode.nullable Decode.string) Nothing
        |> optional "repository_url_field_slug" (Decode.nullable Decode.string) Nothing


assignmentFieldsDecoder : Decode.Decoder (List AssignmentField)
assignmentFieldsDecoder =
    Decode.list assignmentFieldDecoder


assignmentFieldDecoder : Decode.Decoder AssignmentField
assignmentFieldDecoder =
    Decode.succeed AssignmentField
        |> required "slug" Decode.string
        |> required "assignment_slug" Decode.string
        |> required "label" Decode.string
        |> required "help" Decode.string
        |> required "placeholder" Decode.string
        |> required "example" Decode.string
        |> required "pattern" Decode.string
        |> required "is_url" Decode.bool
        |> required "is_multiline" Decode.bool
        |> required "display_order" Decode.int
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime


assignmentSubmissionsDecoder : Decode.Decoder (List AssignmentSubmission)
assignmentSubmissionsDecoder =
    Decode.list assignmentSubmissionDecoder


assignmentSubmissionDecoder : Decode.Decoder AssignmentSubmission
assignmentSubmissionDecoder =
    Decode.succeed AssignmentSubmission
        |> required "id" Decode.int
        |> required "assignment_slug" Decode.string
        |> required "is_team" Decode.bool
        |> required "user_id" (Decode.nullable Decode.int)
        |> required "team_nickname" (Decode.nullable Decode.string)
        |> required "submitter_user_id" Decode.int
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime
        |> optional "fields" assignmentFieldSubmissionsDecoder emptyAssignmentFieldSubmissionList


assignmentFieldSubmissionsDecoder : Decode.Decoder (List AssignmentFieldSubmission)
assignmentFieldSubmissionsDecoder =
    Decode.list assignmentFieldSubmissionDecoder


{-| Test if an assignment submission belongs to the user. That is,
the submission has the user's user\_id or user's team\_nickname.
By design, only one of the these fields will exist for the
submission---the other will be Nothing.
-}
submissionBelongsToUser : CurrentUser -> AssignmentSubmission -> Bool
submissionBelongsToUser u sub =
    case ( sub.user_id, u.team_nickname, sub.team_nickname ) of
        ( Just user_id, _, _ ) ->
            user_id == u.id

        ( _, Just nick1, Just nick2 ) ->
            nick1 == nick2

        ( _, _, _ ) ->
            False


assignmentFieldSubmissionDecoder : Decode.Decoder AssignmentFieldSubmission
assignmentFieldSubmissionDecoder =
    Decode.succeed AssignmentFieldSubmission
        |> required "assignment_submission_id" Decode.int
        |> required "assignment_field_slug" Decode.string
        |> required "assignment_slug" Decode.string
        |> required "body" Decode.string
        |> required "submitter_user_id" Decode.int
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime


{-| What authapp reports about a student's repository for one assignment,
from `GET`/`POST /auth/assignments/{slug}/repository`. `Copying` means the
repository exists but GitHub is still filling it from the template, which
the client waits out by polling. The two `Needs*` states are prerequisites
the student has to sort out first; `joinUrl` is where to do that when the
server knows.
-}
type RepositoryState
    = Ready
    | Copying
    | NeedsGithubLink
    | NeedsOrgJoin


type alias RepositoryStatus =
    { state : RepositoryState
    , repoUrl : Maybe String
    , joinUrl : Maybe String
    }


{-| A refused or failed repository request. `code` is the server's error
code when it sent one, or a client-side stand-in (`network_error`,
`timeout`, `session_expired`, `http_503`, ...) when it did not.
`httpStatus` is 0 when no response arrived at all. `retryAfterSeconds` is
the `Retry-After` header, or the 30 seconds assumed for a 429 that came
without one.
-}
type alias RepositoryError =
    { code : String
    , retryable : Bool
    , httpStatus : Int
    , retryAfterSeconds : Maybe Int
    }


{-| Where the client is with one assignment's repository.

`Checking` is a status request out with nothing known yet, so the view
shows neither a create button nor a stale answer. `Polling` is the wait
for GitHub's copy: `since` bounds it (see `Assignments.Updates`), `inFlight`
keeps one status request out at a time, and `notBefore` holds off the next
one when the server asked for that with `Retry-After`. `PollTimedOut` keeps
the last status so the view can still link to the repository. `Blocked` and
`Failed` carry a `notBefore` of their own: a rate limit on the request that
put them there keeps their buttons off until it is over.

-}
type RepositoryProgress
    = Checking
    | NotStarted
    | Creating
    | Polling PollingRepository
    | Done RepositoryStatus
    | Blocked BlockedRepository
    | Failed FailedRepository
    | PollTimedOut RepositoryStatus


type alias PollingRepository =
    { since : Posix
    , last : RepositoryStatus
    , inFlight : Bool
    , notBefore : Maybe Posix
    }


{-| `joinCancelled` is set when the student came back from the GitHub
authorization page without finishing it (issue #399), so the page can say
so rather than just show the join button again.
-}
type alias BlockedRepository =
    { status : RepositoryStatus
    , notBefore : Maybe Posix
    , joinCancelled : Bool
    }


{-| How the GitHub organization join (issue #399) ended, as authapp
reports it in the `github_join` marker it sends the student back with.
-}
type GithubJoinResult
    = JoinOk
    | JoinDenied
    | JoinError String


{-| The marker is `ok`, `denied` or `error:<code>`. Anything else is
nobody's, and is treated as no marker at all.
-}
githubJoinResult : String -> Maybe GithubJoinResult
githubJoinResult marker =
    if marker == "ok" then
        Just JoinOk

    else if marker == "denied" then
        Just JoinDenied

    else if String.startsWith "error:" marker && String.length marker > 6 then
        Just (JoinError (String.dropLeft 6 marker))

    else
        Nothing


type alias FailedRepository =
    { error : RepositoryError
    , notBefore : Maybe Posix
    }


type alias AssignmentRepositories =
    Dict AssignmentSlug RepositoryProgress


{-| The number of the latest request sent for each assignment's repository.
Every request carries the number it was sent under, and a reply whose
number is no longer current is dropped: a status check that was out when
the student clicked "Create" must not land after the create and put the
page back to "not started".
-}
type alias RepositoryGenerations =
    Dict AssignmentSlug Int


repositoryStatusDecoder : Decode.Decoder RepositoryStatus
repositoryStatusDecoder =
    Decode.succeed RepositoryStatus
        |> required "state" repositoryStateDecoder
        |> optional "repo_url" (Decode.nullable Decode.string) Nothing
        |> optional "join_url" (Decode.nullable Decode.string) Nothing


repositoryStateDecoder : Decode.Decoder RepositoryState
repositoryStateDecoder =
    Decode.string
        |> Decode.andThen
            (\state ->
                case state of
                    "ready" ->
                        Decode.succeed Ready

                    "copying" ->
                        Decode.succeed Copying

                    "needs_github_link" ->
                        Decode.succeed NeedsGithubLink

                    "needs_org_join" ->
                        Decode.succeed NeedsOrgJoin

                    _ ->
                        Decode.fail ("Unknown repository state: " ++ state)
            )


{-| The `{"error": {"code", "retryable"}}` body. The status and the
`Retry-After` header are not in the body, so the request code fills them in
afterwards.
-}
repositoryErrorDecoder : Decode.Decoder RepositoryError
repositoryErrorDecoder =
    Decode.field "error"
        (Decode.succeed RepositoryError
            |> required "code" Decode.string
            |> required "retryable" Decode.bool
            |> hardcoded 0
            |> hardcoded Nothing
        )


type NotSubmissibleReason
    = IsDraft
    | IsAfterClosed
    | MissingTeam


type SubmissibleState
    = Submissible Assignment
    | NotSubmissible NotSubmissibleReason


type AssignmentSubmissionAction
    = CanBeginAssignment Assignment
    | CanUpdateAssignment Assignment AssignmentSubmission
    | CannotSubmitAssignment NotSubmissibleReason


isSubmissible : Posix -> Maybe AssignmentGradeException -> Assignment -> CurrentUser -> SubmissibleState
isSubmissible currentDate maybeException assignment user =
    if assignment.is_draft then
        NotSubmissible IsDraft

    else if assignment.is_team && user.team_nickname == Nothing then
        NotSubmissible MissingTeam

    else if assignment.is_open == False then
        case maybeException of
            Just exception ->
                if dateIsLessThan currentDate exception.closed_at then
                    Submissible assignment

                else
                    NotSubmissible IsAfterClosed

            Nothing ->
                NotSubmissible IsAfterClosed

    else if dateIsLessThan currentDate assignment.closed_at then
        Submissible assignment

    else
        NotSubmissible IsAfterClosed


assignmentSubmissionAction : Posix -> Maybe AssignmentGradeException -> Assignment -> CurrentUser -> Maybe AssignmentSubmission -> AssignmentSubmissionAction
assignmentSubmissionAction currentDate maybeException assignment user maybeSubmission =
    case isSubmissible currentDate maybeException assignment user of
        Submissible assignment2 ->
            case maybeSubmission of
                Just submission ->
                    CanUpdateAssignment assignment2 submission

                Nothing ->
                    CanBeginAssignment assignment2

        NotSubmissible reason ->
            CannotSubmitAssignment reason


notSubmissibleMessage : NotSubmissibleReason -> String
notSubmissibleMessage reason =
    case reason of
        IsAfterClosed ->
            "This assignment is now closed for submissions."

        IsDraft ->
            "This assignment is still in draft mode and cannot yet be submitted."

        MissingTeam ->
            "This is a team assignment. You must join a team before you can submit. Please complete the team selection assignment first."


type alias AssignmentGrade =
    { assignment_slug : String
    , assignment_submission_id : Int
    , points : Float
    , points_possible : Int
    , description : Maybe String
    , created_at : Posix
    , updated_at : Posix
    }

assignmentGradeDecoder : Decode.Decoder AssignmentGrade
assignmentGradeDecoder =
    Decode.succeed AssignmentGrade
        |> required "assignment_slug" Decode.string
        |> required "assignment_submission_id" Decode.int
        |> required "points" Decode.float
        |> required "points_possible" Decode.int
        |> required "description" (Decode.nullable Decode.string)
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime


assignmentGradesDecoder : Decode.Decoder (List AssignmentGrade)
assignmentGradesDecoder =
    Decode.list assignmentGradeDecoder


type alias AssignmentGradeDistribution =
    { assignment_slug : String
    , count : Int
    , average : Float
    , min : Float
    , max : Float
    , points_possible : Int
    , stddev : Float
    , grades : List Float
    }


assignmentGradeDistributionDecoder : Decode.Decoder AssignmentGradeDistribution
assignmentGradeDistributionDecoder =
    Decode.succeed AssignmentGradeDistribution
        |> required "assignment_slug" Decode.string
        |> required "count" Decode.int
        |> required "average" Decode.float
        |> required "min" Decode.float
        |> required "max" Decode.float
        |> required "points_possible" Decode.int
        |> required "stddev" Decode.float
        |> required "grades" (Decode.list Decode.float)


assignmentGradeDistributionsDecoder : Decode.Decoder (List AssignmentGradeDistribution)
assignmentGradeDistributionsDecoder =
    Decode.list assignmentGradeDistributionDecoder


type alias AssignmentGradeException =
    { id : Int
    , assignment_slug : AssignmentSlug
    , is_team : Bool
    , user_id : Maybe Int
    , team_nickname : Maybe String
    , fractional_credit : Float
    , closed_at : Posix
    , created_at : Posix
    , updated_at : Posix
    }


assignmentGradeExceptionDecoder : Decode.Decoder AssignmentGradeException
assignmentGradeExceptionDecoder =
    Decode.succeed AssignmentGradeException
        |> required "id" Decode.int
        |> required "assignment_slug" Decode.string
        |> required "is_team" Decode.bool
        |> required "user_id" (Decode.nullable Decode.int)
        |> required "team_nickname" (Decode.nullable Decode.string)
        |> required "fractional_credit" Decode.float
        |> required "closed_at" Json.Decode.Extra.datetime
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime


assignmentGradeExceptionsDecoder : Decode.Decoder (List AssignmentGradeException)
assignmentGradeExceptionsDecoder =
    Decode.list assignmentGradeExceptionDecoder
