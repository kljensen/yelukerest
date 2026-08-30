module Engagements.Commands exposing
    ( encodeEngagement
    , fetchEngagements
    , fetchEngagementsUrl
    , maybeSubmitEngagement
    , submitEngagement
    )

import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser, JWT)
import Engagements.Model exposing (Engagement, engagementDecoder, engagementsDecoder)
import Http
import Json.Encode as Encode
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


submitTimeoutMilliseconds : Float
submitTimeoutMilliseconds =
    15000


fetchEngagementsUrl : String
fetchEngagementsUrl =
    "/rest/engagements"


fetchEngagements : CurrentUser -> Cmd Msg
fetchEngagements currentUser =
    fetchForCurrentUser currentUser fetchEngagementsUrl engagementsDecoder Msgs.OnFetchEngagements


{-| Save one person's participation for one meeting.

The timeout is what keeps a row recoverable. Saves for a row are serialised, so
while one is in flight a click only queues behind it; a request that never
answers would leave the row saying "Saving…" and refusing to start another one
until the page is reloaded.

-}
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
                , timeout = Just submitTimeoutMilliseconds
                , expect = Http.expectJson (RemoteData.fromResult >> msg) engagementDecoder
                , tracker = Nothing
                , body = Http.jsonBody (encodeEngagement meetingSlug userID participationLevel)
                }
    in
    request


{-| Send a save only if `Engagements.Updates` decided one is due now; a click
made while a request is in flight is queued instead of sent.
-}
maybeSubmitEngagement : JWT -> String -> Int -> Maybe String -> Cmd Msg
maybeSubmitEngagement jwt meetingSlug userID maybeParticipationLevel =
    case maybeParticipationLevel of
        Just participationLevel ->
            submitEngagement jwt meetingSlug userID participationLevel

        Nothing ->
            Cmd.none


encodeEngagement : String -> Int -> String -> Encode.Value
encodeEngagement meetingSlug userID participationLevel =
    Encode.object
        [ ( "meeting_slug", Encode.string meetingSlug )
        , ( "user_id", Encode.int userID )
        , ( "participation", Encode.string participationLevel )
        ]
