module Users.Model
    exposing
        ( JWT
        , User
        , niceName
        , usersDecoder
        )

import Json.Decode as Decode
import Json.Decode.Pipeline exposing (decode, optional, required)
import String exposing (isEmpty)


type alias JWT =
    String


type alias User =
    { id : Int
    , netid : String
    , role : String
    , email : Maybe String
    , name : Maybe String
    , known_as : Maybe String
    , nickname : String
    , team_nickname : Maybe String
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
        |> required "email" (Decode.nullable Decode.string)
        |> required "name" (Decode.nullable Decode.string)
        |> required "known_as" (Decode.nullable Decode.string)
        |> required "nickname" Decode.string
        |> required "team_nickname" (Decode.nullable Decode.string)


niceName : User -> String
niceName user =
    let
        noNameDefault =
            "User id#" ++ toString user.id ++ " (netid =" ++ user.netid ++ ")"

        prefix =
            case user.name of
                Just name ->
                    if isEmpty name then
                        noNameDefault
                    else
                        name

                Nothing ->
                    noNameDefault

        suffix =
            case user.known_as of
                Just known_as ->
                    if isEmpty known_as then
                        ""
                    else
                        " (" ++ known_as ++ ")"

                Nothing ->
                    ""
    in
    prefix ++ suffix
