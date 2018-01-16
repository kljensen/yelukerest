module Assignments.Commands exposing (..)

import Assignments.Model exposing (Assignment, assignmentsDecoder)
import Auth.Model exposing (CurrentUser)
import Http
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


fetchAssignments : WebData CurrentUser -> Cmd Msg
fetchAssignments currentUser =
    case currentUser of
        RemoteData.Success currentUser ->
            sendRequestForAssignments currentUser

        _ ->
            Cmd.none


sendRequestForAssignments : CurrentUser -> Cmd Msg
sendRequestForAssignments currentUser =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ currentUser.jwt)
            ]

        request =
            Http.request
                { method = "GET"
                , headers = headers
                , url = fetchAssignmentsUrl
                , timeout = Nothing
                , expect = Http.expectJson assignmentsDecoder
                , withCredentials = False
                , body = Http.emptyBody
                }
    in
    request
        |> RemoteData.sendRequest
        |> Cmd.map Msgs.OnFetchAssignments


fetchAssignmentsUrl : String
fetchAssignmentsUrl =
    "/rest/assignments?order=closed_at"
