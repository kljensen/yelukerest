module Assignments.Model exposing (Assignment, AssignmentSlug, assignmentsDecoder)

import Date exposing (Date)
import Json.Decode as Decode
import Json.Decode.Extra exposing (date)
import Json.Decode.Pipeline exposing (decode, required)


type alias AssignmentSlug =
    String


type alias Assignment =
    { slug : String
    , possible_points : Int
    , is_draft : Bool
    , is_markdown : Bool
    , is_team : Bool
    , is_open : Bool
    , title : String
    , body : String
    , closed_at : Date
    }


assignmentsDecoder : Decode.Decoder (List Assignment)
assignmentsDecoder =
    Decode.list assignmentDecoder


assignmentDecoder : Decode.Decoder Assignment
assignmentDecoder =
    decode Assignment
        |> required "slug" Decode.string
        |> required "possible_points" Decode.int
        |> required "is_draft" Decode.bool
        |> required "is_markdown" Decode.bool
        |> required "is_team" Decode.bool
        |> required "is_open" Decode.bool
        |> required "title" Decode.string
        |> required "body" Decode.string
        |> required "closed_at" Json.Decode.Extra.date
