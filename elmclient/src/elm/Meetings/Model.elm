module Meetings.Model exposing (Meeting, MeetingSlug, meetingsDecoder)

import Json.Decode as Decode
import Json.Decode.Extra
import Json.Decode.Pipeline exposing (required)
import Time exposing (Posix)


type alias MeetingSlug =
    String


type alias Meeting =
    { slug : String
    , title : String
    , summary : Maybe String
    , description : String
    , begins_at : Posix
    , is_draft : Bool
    }


meetingsDecoder : Decode.Decoder (List Meeting)
meetingsDecoder =
    Decode.list meetingDecoder


meetingDecoder : Decode.Decoder Meeting
meetingDecoder =
    Decode.succeed Meeting
        |> required "slug" Decode.string
        |> required "title" Decode.string
        |> required "summary" (Decode.nullable Decode.string)
        |> required "description" Decode.string
        |> required "begins_at" Json.Decode.Extra.datetime
        |> required "is_draft" Decode.bool



-- Encoder not yet needed
