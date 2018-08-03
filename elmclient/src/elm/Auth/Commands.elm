module Auth.Commands exposing (..)

import Auth.Model exposing (CurrentUser, JWT, currentUserDecoder)
import Http
import Json.Decode as Decode
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


fetchCurrentUser : Cmd Msg
fetchCurrentUser =
    Http.get fetchCurrentUserUrl currentUserDecoder
        |> RemoteData.sendRequest
        |> Cmd.map Msgs.OnFetchCurrentUser


fetchCurrentUserUrl : String
fetchCurrentUserUrl =
    "/auth/me"


fetchForCurrentUser : CurrentUser -> String -> Decode.Decoder a -> (WebData a -> Msg) -> Cmd Msg
fetchForCurrentUser currentUser url decoder data2msg =
    sendRequestWithJWT currentUser.jwt url decoder data2msg


sendRequestWithJWT : JWT -> String -> Decode.Decoder a -> (WebData a -> Msg) -> Cmd Msg
sendRequestWithJWT jwt url decoder data2msg =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            ]

        request =
            Http.request
                { method = "GET"
                , headers = headers
                , url = url
                , timeout = Nothing
                , expect = Http.expectJson decoder
                , withCredentials = False
                , body = Http.emptyBody
                }
    in
    request
        |> RemoteData.sendRequest
        |> Cmd.map data2msg



-- |> Msgs.OnFetchCurrentUser
-- |> Cmd.map msg
