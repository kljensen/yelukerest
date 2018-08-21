module Auth.Model exposing (CurrentUser, JWT, currentUserDecoder)

import Json.Decode as Decode
import Json.Decode.Pipeline exposing (decode, required, optional)


type alias JWT =
    String


type alias CurrentUser =
    { id : Int
    , netid : String
    , jwt : JWT
    , role: String
    , nickname: String
    , team_nickname: Maybe String
    }


currentUserDecoder : Decode.Decoder CurrentUser
currentUserDecoder =
    decode CurrentUser
        |> required "id" Decode.int
        |> required "netid" Decode.string
        |> required "jwt" Decode.string
        |> required "role" Decode.string
        |> required "nickname" Decode.string
        |> required "team_nickname" (Decode.nullable Decode.string)

