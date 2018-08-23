module Engagements.Model exposing (Engagement, engagementsDecoder)
import Date exposing (Date)
import Json.Decode as Decode
import Json.Decode.Extra exposing (date)
import Json.Decode.Pipeline exposing (decode, required)

type alias Engagement =
    { user_id : Int
    , meeting_id : Int
    , participation : String
    , created_at : Date
    , updated_at : Date
    }


engagementsDecoder : Decode.Decoder (List Engagement)
engagementsDecoder =
    Decode.list engagementDecoder


engagementDecoder : Decode.Decoder Engagement
engagementDecoder =
    decode Engagement
        |> required "user_id" Decode.int
        |> required "meeting_id" Decode.int
        |> required "participation" Decode.string
        |> required "created_at" Json.Decode.Extra.date
        |> required "updated_at" Json.Decode.Extra.date
