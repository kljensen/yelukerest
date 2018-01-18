module Auth.Model exposing (CurrentUser, JWT, currentUserDecoder)

import Json.Decode as Decode
import Json.Decode.Pipeline exposing (decode, required)


type alias JWT =
    String


type alias CurrentUser =
    { id : Int
    , netid : String
    , jwt : JWT
    }


currentUserDecoder : Decode.Decoder CurrentUser
currentUserDecoder =
    decode CurrentUser
        |> required "id" Decode.int
        |> required "netid" Decode.string
        |> required "jwt" Decode.string
