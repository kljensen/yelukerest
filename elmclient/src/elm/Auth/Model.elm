module Auth.Model exposing (CurrentUser, JWT, currentUserDecoder, isFacultyOrTA)

import Json.Decode as Decode
import Json.Decode.Pipeline exposing (decode, optional, required)


type alias JWT =
    String


type alias CurrentUser =
    { id : Int
    , netid : String
    , jwt : JWT
    , role : String
    , nickname : String
    , team_nickname : Maybe String
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


isFacultyOrTA : String -> Bool
isFacultyOrTA role =
    List.member role [ "ta", "faculty" ]
