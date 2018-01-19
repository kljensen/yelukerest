module Meetings.Views exposing (detailView, listView)

import Common.Views
import Date
import Date.Format as DateFormat
import Html exposing (Html)
import Html.Attributes as Attrs
import Markdown
import Meetings.Model exposing (Meeting, MeetingSlug)
import Msgs exposing (Msg)
import Quizzes.Model exposing (Quiz)
import RemoteData exposing (WebData)


listView : WebData (List Meeting) -> Html Msg
listView meetings =
    Html.div [] [ listOrStatus meetings ]



-- getQuizForMeeting


detailView : WebData (List Meeting) -> MeetingSlug -> List Quiz -> Html.Html Msg
detailView : WebData (List Meeting) -> MeetingSlug -> WebData (List Quiz) -> Html.Html Msg
detailView meetings slug quizzes =
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
    DateFormat.format "%a %d%b" date


showDraftStatus : Bool -> Html.Html Msg
showDraftStatus is_draft =
    case is_draft of
        True ->
            Html.span [ Attrs.class "meeting-draft" ]
                [ Html.text "[draft]" ]

        False ->
            Html.text ""


detailViewForJustMeeting : Meeting -> Html.Html Msg
detailViewForJustMeeting meeting =
    Html.div []
        [ Html.h1 [] [ Html.text meeting.title, showDraftStatus meeting.is_draft ]
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
    let
        meetingDetails =
            List.map (\m -> { date = m.begins_at, title = m.title, href = "#meetings/" ++ m.slug }) meetings
    in
    Html.div [] (List.map Common.Views.dateTitleHrefRow meetingDetails)



-- listDateTitleLinkView
