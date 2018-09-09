module Assignments.Model
    exposing
        ( Assignment
        , AssignmentField
        , AssignmentFieldSubmission
        , AssignmentFieldSubmissionInputs
        , AssignmentGrade
        , AssignmentGradeDistribution
        , AssignmentSlug
        , AssignmentSubmission
        , NotSubmissibleReason(..)
        , PendingAssignmentFieldSubmissionRequests
        , PendingBeginAssignments
        , SubmissibleState(..)
        , assignmentFieldSubmissionsDecoder
        , assignmentGradeDistributionsDecoder
        , assignmentGradesDecoder
        , assignmentSubmissionDecoder
        , assignmentSubmissionsDecoder
        , assignmentsDecoder
        , isSubmissible
        )

import Common.Comparisons exposing (dateIsLessThan)
import Date exposing (Date)
import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Decode.Extra exposing (date)
import Json.Decode.Pipeline exposing (decode, hardcoded, optional, required)
import RemoteData exposing (WebData)


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
    , closed_at : Date
    , fields : List AssignmentField
    }


type alias AssignmentField =
    { id : Int
    , assignment_slug : String
    , label : String
    , help : String
    , placeholder : String
    , is_url : Bool
    , is_multiline : Bool
    , display_order : Int
    , created_at : Date
    , updated_at : Date
    }


type alias AssignmentSubmission =
    { id : Int
    , assignment_slug : String
    , is_team : Bool
    , user_id : Maybe Int
    , team_nickname : Maybe String
    , submitter_user_id : Int
    , created_at : Date
    , updated_at : Date
    , fields : List AssignmentFieldSubmission
    }


type alias AssignmentFieldSubmission =
    { assignment_submission_id : Int
    , assignment_field_id : Int
    , assignment_slug : String
    , body : String
    , submitter_user_id : Int
    , created_at : Date
    , updated_at : Date
    }


type alias AssignmentFieldSubmissionInputs =
    Dict Int String


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
    decode Assignment
        |> required "slug" Decode.string
        |> required "points_possible" Decode.int
        |> required "is_draft" Decode.bool
        |> required "is_markdown" Decode.bool
        |> required "is_team" Decode.bool
        |> required "is_open" Decode.bool
        |> required "title" Decode.string
        |> required "body" Decode.string
        |> required "closed_at" Json.Decode.Extra.date
        |> required "fields" assignmentFieldsDecoder


assignmentFieldsDecoder : Decode.Decoder (List AssignmentField)
assignmentFieldsDecoder =
    Decode.list assignmentFieldDecoder


assignmentFieldDecoder : Decode.Decoder AssignmentField
assignmentFieldDecoder =
    decode AssignmentField
        |> required "id" Decode.int
        |> required "assignment_slug" Decode.string
        |> required "label" Decode.string
        |> required "help" Decode.string
        |> required "placeholder" Decode.string
        |> required "is_url" Decode.bool
        |> required "is_multiline" Decode.bool
        |> required "display_order" Decode.int
        |> required "created_at" Json.Decode.Extra.date
        |> required "updated_at" Json.Decode.Extra.date


assignmentSubmissionsDecoder : Decode.Decoder (List AssignmentSubmission)
assignmentSubmissionsDecoder =
    Decode.list assignmentSubmissionDecoder


assignmentSubmissionDecoder : Decode.Decoder AssignmentSubmission
assignmentSubmissionDecoder =
    decode AssignmentSubmission
        |> required "id" Decode.int
        |> required "assignment_slug" Decode.string
        |> required "is_team" Decode.bool
        |> required "user_id" (Decode.nullable Decode.int)
        |> required "team_nickname" (Decode.nullable Decode.string)
        |> required "submitter_user_id" Decode.int
        |> required "created_at" Json.Decode.Extra.date
        |> required "updated_at" Json.Decode.Extra.date
        |> optional "fields" assignmentFieldSubmissionsDecoder emptyAssignmentFieldSubmissionList


assignmentFieldSubmissionsDecoder : Decode.Decoder (List AssignmentFieldSubmission)
assignmentFieldSubmissionsDecoder =
    Decode.list assignmentFieldSubmissionDecoder


assignmentFieldSubmissionDecoder : Decode.Decoder AssignmentFieldSubmission
assignmentFieldSubmissionDecoder =
    decode AssignmentFieldSubmission
        |> required "assignment_submission_id" Decode.int
        |> required "assignment_field_id" Decode.int
        |> required "assignment_slug" Decode.string
        |> required "body" Decode.string
        |> required "submitter_user_id" Decode.int
        |> required "created_at" Json.Decode.Extra.date
        |> required "updated_at" Json.Decode.Extra.date


type NotSubmissibleReason
    = IsDraft
    | IsAfterClosed


type SubmissibleState
    = Submissible Assignment
    | NotSubmissible NotSubmissibleReason


isSubmissible : Date.Date -> Assignment -> SubmissibleState
isSubmissible currentDate assignment =
    if assignment.is_draft then
        NotSubmissible IsDraft
    else if assignment.is_open == False then
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
    , created_at : Date
    , updated_at : Date
    }


assignmentGradeDecoder : Decode.Decoder AssignmentGrade
assignmentGradeDecoder =
    decode AssignmentGrade
        |> required "assignment_slug" Decode.string
        |> required "assignment_submission_id" Decode.int
        |> required "points" Decode.float
        |> required "points_possible" Decode.int
        |> required "created_at" Json.Decode.Extra.date
        |> required "updated_at" Json.Decode.Extra.date


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
    decode AssignmentGradeDistribution
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
