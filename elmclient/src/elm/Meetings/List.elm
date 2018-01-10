module Meetings.List exposing (view)

import Html exposing (Html)
import Html.Attributes
import Meetings.Model exposing (Meeting)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


view : WebData (List Meeting) -> Html Msg
view meetings =
    Html.div [] [ listOrStatus meetings ]


nav : Html Msg
nav =
    Html.div [ Html.Attributes.class "clearfix mb2 white bg-black" ]
        [ Html.div [ Html.Attributes.class "left p2" ] [ Html.text "Players" ] ]


listOrStatus : WebData (List Meeting) -> Html Msg
listOrStatus meetings =
    case meetings of
        RemoteData.NotAsked ->
            Html.text ""

        RemoteData.Loading ->
            Html.text "Loading..."

        RemoteData.Success meetings ->
            listMeetings meetings

        RemoteData.Failure error ->
            Html.text (toString error)


listMeetings : List Meeting -> Html Msg
listMeetings meetings =
    Html.div [] [ Html.ul [] (List.map meetingRow meetings) ]


meetingRow : Meeting -> Html Msg
meetingRow meeting =
    let
        meetingDetailPath =
            meeting.slug
    in
    Html.li []
        [ Html.a [ Html.Attributes.href meetingDetailPath ] [ Html.text meeting.title ]
        ]
