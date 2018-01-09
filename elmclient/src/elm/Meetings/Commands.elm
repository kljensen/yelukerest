module Meetings.Commands exposing (..)

import Http
import Meetings.Model exposing (Meeting, meetingsDecoder)
import Msgs exposing (Msg)
import RemoteData


fetchMeetings : Cmd Msg
fetchMeetings =
    Http.get fetchMeetingsUrl meetingsDecoder
        |> RemoteData.sendRequest
        |> Cmd.map Msgs.OnFetchMeetings


fetchMeetingsUrl : String
fetchMeetingsUrl =
    "/rest/meetings"
