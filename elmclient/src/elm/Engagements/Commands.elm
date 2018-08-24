module Engagements.Commands exposing (..)

import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser, JWT)
import Engagements.Model exposing (Engagement, engagementDecoder, engagementsDecoder)
import Http
import Json.Encode as Encode
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


fetchEngagementsUrl : String
fetchEngagementsUrl =
    "/rest/engagements"


fetchEngagements : CurrentUser -> Cmd Msg
fetchEngagements currentUser =
    fetchForCurrentUser currentUser fetchEngagementsUrl engagementsDecoder Msgs.OnFetchEngagements


submitEngagement : JWT -> Int -> Int -> String -> Cmd Msg
submitEngagement jwt meetingID userID participationLevel =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation,resolution=merge-duplicates"
            , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]

        request =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/engagements"
                , timeout = Nothing
                , expect = Http.expectJson engagementDecoder
                , withCredentials = False
                , body = Http.jsonBody (encodeEngagement meetingID userID participationLevel)
                }
    in
    request
        |> RemoteData.sendRequest
        |> Cmd.map (Msgs.OnSubmitEngagementResponse meetingID userID)


encodeEngagement : Int -> Int -> String -> Encode.Value
encodeEngagement meetingID userID participationLevel =
    Encode.object
        [ ( "meeting_id", Encode.int meetingID )
        , ( "user_id", Encode.int userID )
        , ( "participation", Encode.string participationLevel )
        ]
