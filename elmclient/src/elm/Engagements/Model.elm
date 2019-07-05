module Engagements.Model exposing (Engagement, engagementDecoder, engagementsDecoder, participationEnum)

import Json.Decode as Decode exposing (Decoder)
import Json.Decode.Extra exposing (datetime)
import Json.Decode.Pipeline exposing (required)
import Time exposing (Posix)


type alias Engagement =
    { user_id : Int
    , meeting_slug : String
    , participation : String
    , created_at : Posix
    , updated_at : Posix
    }


participationEnum : List String
participationEnum =
    [ "absent", "attended", "contributed", "led" ]


engagementsDecoder : Decode.Decoder (List Engagement)
engagementsDecoder =
    Decode.list engagementDecoder


engagementDecoder : Decode.Decoder Engagement
engagementDecoder =
    Decode.succeed Engagement
        |> required "user_id" Decode.int
        |> required "meeting_slug" Decode.string
        |> required "participation" Decode.string
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime
