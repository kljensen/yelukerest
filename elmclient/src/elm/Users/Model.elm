module Users.Model exposing
    ( JWT
    , User
    , UserSecret
    , niceName
    , userSecretsDecoder
    , usersDecoder
    )

import Json.Decode as Decode
import Json.Decode.Pipeline exposing (optional, required)
import String exposing (fromInt, isEmpty)


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
    Decode.succeed User
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
            "User id#" ++ fromInt user.id ++ " (netid =" ++ user.netid ++ ")"

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
                Just knownAs ->
                    if isEmpty knownAs then
                        ""

                    else
                        showSuffixWithKnownAs prefix knownAs

                Nothing ->
                    ""
    in
    prefix ++ suffix


showSuffixWithKnownAs : String -> String -> String
showSuffixWithKnownAs name knownAs =
    let
        nameIncludesNickname =
            List.member knownAs (String.split " " name)
    in
    case nameIncludesNickname of
        True ->
            ""

        False ->
            " (" ++ knownAs ++ ")"


type alias UserSecret =
    { id : Int
    , user_id : Maybe Int
    , team_nickname : Maybe String
    , slug : String
    , body : String
    }


userSecretDecoder : Decode.Decoder UserSecret
userSecretDecoder =
    Decode.succeed UserSecret
        |> required "id" Decode.int
        |> required "user_id" (Decode.nullable Decode.int)
        |> required "team_nickname" (Decode.nullable Decode.string)
        |> required "slug" Decode.string
        |> required "body" Decode.string


userSecretsDecoder : Decode.Decoder (List UserSecret)
userSecretsDecoder =
    Decode.list userSecretDecoder
