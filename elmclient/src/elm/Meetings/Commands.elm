module Meetings.Commands exposing (fetchMeetings, fetchMeetingsUrl)

import Http
import Meetings.Model exposing (Meeting, meetingsDecoder)
import Msgs exposing (Msg)
import RemoteData


fetchMeetings : Cmd Msg
fetchMeetings =
    Http.get
        { url = fetchMeetingsUrl
        , expect = Http.expectJson (RemoteData.fromResult >> Msgs.OnFetchMeetings) meetingsDecoder
        }


fetchMeetingsUrl : String
fetchMeetingsUrl =
    "/rest/meetings?order=begins_at"
