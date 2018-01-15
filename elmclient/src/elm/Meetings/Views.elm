module Meetings.Views exposing (detailView, listView)

import Date
import Date.Format as DateFormat
import Html exposing (Html)
import Html.Attributes as Attrs
import Markdown
import Meetings.Model exposing (Meeting, MeetingSlug)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


listView : WebData (List Meeting) -> Html Msg
listView meetings =
    Html.div [] [ listOrStatus meetings ]


detailView : WebData (List Meeting) -> MeetingSlug -> Html.Html Msg
detailView meetings slug =
    case meetings of
        RemoteData.NotAsked ->
            Html.text ""

        RemoteData.Loading ->
            Html.text "Loading ..."

        RemoteData.Success meetings ->
            let
                maybeMeeting =
                    meetings
                        |> List.filter (\meeting -> meeting.slug == slug)
                        |> List.head
            in
            case maybeMeeting of
                Just meeting ->
                    detailViewForJustMeeting meeting

                Nothing ->
                    meetingNotFoundView slug

        RemoteData.Failure err ->
            Html.text (toString err)


dateToString : Date.Date -> String
dateToString date =
    DateFormat.format "%l%p %A, %B %e" date


shortDateToString : Date.Date -> String
shortDateToString date =
    DateFormat.format "%a %m%b" date


detailViewForJustMeeting : Meeting -> Html.Html Msg
detailViewForJustMeeting meeting =
    Html.div []
        [ Html.h1 [] [ Html.text meeting.title ]
        , Html.div []
            [ Html.time [] [ Html.text (dateToString meeting.begins_at) ]
            ]
        , Markdown.toHtml [] meeting.description
        ]


meetingNotFoundView : String -> Html msg
meetingNotFoundView slug =
    Html.div []
        [ Html.text ("No such class meeting" ++ slug)
        ]


nav : Html Msg
nav =
    Html.div [ Attrs.class "clearfix mb2 white bg-black" ]
        [ Html.div [ Attrs.class "left p2" ] [ Html.text "Players" ] ]


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
            "#meetings/" ++ meeting.slug
    in
    Html.li []
        [ Html.time []
            [ Html.text (shortDateToString meeting.begins_at ++ " — ") ]
        , Html.a
            [ Attrs.href meetingDetailPath ]
            [ Html.text meeting.title ]
        ]
