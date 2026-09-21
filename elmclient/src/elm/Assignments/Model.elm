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
    , MyRepository
    , NotSubmissibleReason(..)
    , PendingAssignmentFieldSubmissionRequests
    , PendingBeginAssignments
    , SubmissibleState(..)
    , assignmentFieldSubmissionsDecoder
    , assignmentGradeDistributionsDecoder
    , assignmentGradeExceptionsDecoder
    , assignmentGradesDecoder
    , assignmentSubmissionDecoder
    , assignmentSubmissionsDecoder
    , assignmentsDecoder
    , assignmentSubmissionAction
    , isSubmissible
    , myRepositoriesDecoder
    , notSubmissibleMessage
    , fieldAcceptsRepositoryUrl
    , repositoryUrlForField
    , submissionBelongsToUser
    , valuesForSubmissionID
    )

import Auth.Model exposing (CurrentUser)
import Common.Comparisons exposing (dateIsLessThan)
import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Decode.Extra
import Json.Decode.Pipeline exposing (optional, required)
import Regex
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
    }


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


{-| A row of api.my\_repositories: a repository the student (or their team)
created from a template, with the assignment the template served, if any,
and the browser URL, which is NULL on a forge the view does not know.
-}
type alias MyRepository =
    { template_slug : String
    , label : String
    , assignment_slug : Maybe String
    , template_full_name : String
    , repo_url : Maybe String
    , is_team : Bool
    , user_id : Maybe Int
    , team_nickname : Maybe String
    , provider_full_name : String
    , created_at : Posix
    }


myRepositoryDecoder : Decode.Decoder MyRepository
myRepositoryDecoder =
    Decode.succeed MyRepository
        |> required "template_slug" Decode.string
        |> required "label" Decode.string
        |> required "assignment_slug" (Decode.nullable Decode.string)
        |> required "template_full_name" Decode.string
        |> required "repo_url" (Decode.nullable Decode.string)
        |> required "is_team" Decode.bool
        |> required "user_id" (Decode.nullable Decode.int)
        |> required "team_nickname" (Decode.nullable Decode.string)
        |> required "provider_full_name" Decode.string
        |> required "created_at" Json.Decode.Extra.datetime


myRepositoriesDecoder : Decode.Decoder (List MyRepository)
myRepositoriesDecoder =
    Decode.list myRepositoryDecoder


{-| Whether a repository URL belongs in this field. An assignment can have
several URL fields (a repository, a Google Doc, a deployed app), and the
hint must not land under the wrong one.

The field's slug or label has to say "repo" or "repository" -- as a word,
since "report" contains "repo" and a sprint-report field is not one. A
pattern cannot stand in for that: patterns like `.*` or `https?://.*` accept
a GitHub URL under any field. What a pattern can do is rule the URL out:
when the field has one that compiles, the URL must match it, anchored as the
browser anchors the pattern attribute on submit. One that does not compile
is ignored.

-}
fieldAcceptsRepositoryUrl : AssignmentField -> String -> Bool
fieldAcceptsRepositoryUrl field url =
    let
        patternAccepts =
            if field.pattern == "" then
                True

            else
                Regex.fromString ("^(?:" ++ field.pattern ++ ")$")
                    |> Maybe.map (\regex -> Regex.contains regex url)
                    |> Maybe.withDefault True

        isRepoWord w =
            w == "repo" || w == "repos" || String.startsWith "reposit" w

        mentionsRepo s =
            String.toLower s
                |> String.map
                    (\c ->
                        if Char.isAlphaNum c then
                            c

                        else
                            ' '
                    )
                |> String.words
                |> List.any isRepoWord
    in
    (mentionsRepo field.slug || mentionsRepo field.label) && patternAccepts


{-| The browser URL of the first repository created for this assignment that
the field accepts, in the order the rows were fetched.
-}
repositoryUrlForField : AssignmentSlug -> AssignmentField -> List MyRepository -> Maybe String
repositoryUrlForField assignmentSlug field repositories =
    repositories
        |> List.filter (\r -> r.assignment_slug == Just assignmentSlug)
        |> List.filterMap .repo_url
        |> List.filter (fieldAcceptsRepositoryUrl field)
        |> List.head


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
