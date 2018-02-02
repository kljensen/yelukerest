module Assignments.Model exposing (Assignment, AssignmentField, AssignmentFieldSubmission, AssignmentSlug, AssignmentSubmission, PendingBeginAssignments, assignmentSubmissionsDecoder, assignmentsDecoder)

import Date exposing (Date)
import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Decode.Extra exposing (date)
import Json.Decode.Pipeline exposing (decode, required)
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


type alias PendingBeginAssignments =
    Dict AssignmentSlug (WebData AssignmentSubmission)


assignmentsDecoder : Decode.Decoder (List Assignment)
assignmentsDecoder =
    Decode.list assignmentDecoder


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
        |> required "fields" assignmentFieldSubmissionsDecoder


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
