module Auth.Commands exposing (..)

import Auth.Model exposing (CurrentUser, currentUserDecoder)
import Http
import Msgs exposing (Msg)
import RemoteData


fetchCurrentUser : Cmd Msg
fetchCurrentUser =
    Http.get fetchCurrentUserUrl currentUserDecoder
        |> RemoteData.sendRequest
        |> Cmd.map Msgs.OnFetchCurrentUser


fetchCurrentUserUrl : String
fetchCurrentUserUrl =
    "/auth/me"
