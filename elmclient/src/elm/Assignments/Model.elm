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
    , isSubmissible
    , submissionBelongsToUser
    , valuesForSubmissionID
    )

import Auth.Model exposing (CurrentUser)
import Common.Comparisons exposing (dateIsLessThan)
import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Decode.Extra
import Json.Decode.Pipeline exposing (optional, required)
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


type NotSubmissibleReason
    = IsDraft
    | IsAfterClosed


type SubmissibleState
    = Submissible Assignment
    | NotSubmissible NotSubmissibleReason


isSubmissible : Posix -> Maybe AssignmentGradeException -> Assignment -> SubmissibleState
isSubmissible currentDate maybeException assignment =
    if assignment.is_draft then
        NotSubmissible IsDraft

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


type alias AssignmentGrade =
    { assignment_slug : String
    , assignment_submission_id : Int
    , points : Float
    , points_possible : Int
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
