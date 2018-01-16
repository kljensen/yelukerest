module Assignments.Commands exposing (..)

import Assignments.Model exposing (Assignment, assignmentsDecoder)
import Http
import Msgs exposing (Msg)
import RemoteData


fetchAssignments : Cmd Msg
fetchAssignments =
    Http.get fetchAssignmentsUrl assignmentsDecoder
        |> RemoteData.sendRequest
        |> Cmd.map Msgs.OnFetchAssignments


fetchAssignmentsUrl : String
fetchAssignmentsUrl =
    "/rest/assignments"
