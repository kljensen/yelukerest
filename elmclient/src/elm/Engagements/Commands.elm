module Engagements.Commands exposing (encodeEngagement, fetchEngagements, fetchEngagementsUrl, submitEngagement)

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


submitEngagement : JWT -> String -> Int -> String -> Cmd Msg
submitEngagement jwt meetingSlug userID participationLevel =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation,resolution=merge-duplicates"
            , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]

        msg =
            Msgs.OnSubmitEngagementResponse meetingSlug userID

        request =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/engagements"
                , timeout = Nothing
                , expect = Http.expectJson (RemoteData.fromResult >> msg) engagementDecoder
                , tracker = Nothing
                , body = Http.jsonBody (encodeEngagement meetingSlug userID participationLevel)
                }
    in
    request


encodeEngagement : String -> Int -> String -> Encode.Value
encodeEngagement meetingSlug userID participationLevel =
    Encode.object
        [ ( "meeting_slug", Encode.string meetingSlug )
        , ( "user_id", Encode.int userID )
        , ( "participation", Encode.string participationLevel )
        ]
