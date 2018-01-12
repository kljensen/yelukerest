module Auth.Model exposing (CurrentUser, currentUserDecoder)

import Json.Decode as Decode
import Json.Decode.Pipeline exposing (decode, required)


type alias CurrentUser =
    { id : Int
    , netid : String
    , jwt : String
    }


currentUserDecoder : Decode.Decoder CurrentUser
currentUserDecoder =
    decode CurrentUser
        |> required "id" Decode.int
        |> required "netid" Decode.string
        |> required "jwt" Decode.string
