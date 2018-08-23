module Users.Model exposing (User, JWT, usersDecoder)

import Json.Decode as Decode
import Json.Decode.Pipeline exposing (decode, required, optional)


type alias JWT =
    String


type alias User =
    { id : Int
    , netid : String
    , role: String
    , nickname: String
    , team_nickname: Maybe String
    }

usersDecoder : Decode.Decoder (List User)
usersDecoder =
    Decode.list userDecoder


userDecoder : Decode.Decoder User
userDecoder =
    decode User
        |> required "id" Decode.int
        |> required "netid" Decode.string
        |> required "role" Decode.string
        |> required "nickname" Decode.string
        |> required "team_nickname" (Decode.nullable Decode.string)

