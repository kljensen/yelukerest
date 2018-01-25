module Common.Views exposing (DateTitleHrefRecord, dateTitleHrefRow, piazzaLink)

import Date exposing (Date)
import Date.Format as DateFormat
import Html exposing (Html)
import Html.Attributes as Attrs
import Msgs exposing (Msg)


type alias DateTitleHrefRecord =
    { date : Date
    , title : String
    , href : String
    }


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


piazzaLink : Maybe String -> Html Msg
piazzaLink piazzaURL =
    case piazzaURL of
        Just url ->
            Html.a [ Attrs.href url ] [ Html.text "Piazza" ]

        Nothing ->
            Html.text ""
