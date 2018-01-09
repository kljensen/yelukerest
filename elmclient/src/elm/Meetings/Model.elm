module Meetings.Model exposing (Meeting, meetingsDecoder)

import Date exposing (Date)
import Json.Decode as Decode
import Json.Decode.Extra exposing (date)
import Json.Decode.Pipeline exposing (decode, required)


type alias Meeting =
    { id : Int
    , slug : String
    , summary : String
    , description : String
    , begins_at : Date
    , is_draft : Bool
    }


meetingsDecoder : Decode.Decoder (List Meeting)
meetingsDecoder =
    Decode.list meetingDecoder


meetingDecoder : Decode.Decoder Meeting
meetingDecoder =
    decode Meeting
        |> required "id" Decode.int
        |> required "slug" Decode.string
        |> required "summary" Decode.string
        |> required "description" Decode.string
        |> required "begins_at" Json.Decode.Extra.date
        |> required "is_draft" Decode.bool



-- Encoder not yet needed
