module Assignments.Commands exposing (..)

import Assignments.Model exposing (assignmentsDecoder)
import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


fetchAssignments : WebData CurrentUser -> Cmd Msg
fetchAssignments currentUser =
    fetchForCurrentUser currentUser fetchAssignmentsUrl assignmentsDecoder Msgs.OnFetchAssignments


fetchAssignmentsUrl : String
fetchAssignmentsUrl =
    "/rest/assignments?order=closed_at"
