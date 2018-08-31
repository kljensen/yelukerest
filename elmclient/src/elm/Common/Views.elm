module Common.Views
    exposing
        ( DateTitleHrefRecord
        , dateTitleHrefRow
        , dateToString
        , divWithText
        , merge4
        , piazzaLink
        , shortDateToString
        , showDraftStatus
        )

import Date exposing (Date)
import Date.Format as DateFormat
import Html exposing (Html)
import Html.Attributes as Attrs
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


type alias DateTitleHrefRecord =
    { date : Date
    , title : String
    , href : String
    }


merge4 :
    WebData a
    -> WebData b
    -> WebData c
    -> WebData d
    -> WebData ( a, b, c, d )
merge4 a b c d =
    RemoteData.map (,,,) a
        |> RemoteData.andMap b
        |> RemoteData.andMap c
        |> RemoteData.andMap d


showDraftStatus : Bool -> Html.Html Msg
showDraftStatus is_draft =
    case is_draft of
        True ->
            Html.span [ Attrs.class "meeting-draft" ]
                [ Html.text "[draft]" ]

        False ->
            Html.text ""


dateTitleHrefRow : DateTitleHrefRecord -> Html Msg
dateTitleHrefRow dth =
    Html.div [ Attrs.class "clearfix mb2" ]
        [ Html.time [ Attrs.class "left p1 mr1 classdate" ]
            [ Html.div [] [ Html.text (DateFormat.format "%a" dth.date) ]
            , Html.div [] [ Html.text (DateFormat.format "%d%b" dth.date) ]
            ]
        , Html.div [ Attrs.class "overflow-hidden p1" ]
            [ Html.a
                [ Attrs.href dth.href ]
                [ Html.text dth.title ]
            ]
        ]


divWithText : String -> Html Msg
divWithText theText =
    Html.div [] [ Html.text theText ]


piazzaLink : Maybe String -> Html Msg
piazzaLink piazzaURL =
    case piazzaURL of
        Just url ->
            Html.a [ Attrs.href url ] [ Html.text "Piazza" ]

        Nothing ->
            Html.text ""


dateToString : Date.Date -> String
dateToString date =
    DateFormat.format "%l:%M%p %A, %B %e, %Y" date


shortDateToString : Date.Date -> String
shortDateToString date =
    DateFormat.format "%a %d%b" date
