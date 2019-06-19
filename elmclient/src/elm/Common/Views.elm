module Common.Views exposing
    ( DateTitleHrefRecord
    , dateTitleHrefRow
    , divWithText
    , longDateToString
    , piazzaLink
    , shortDateToString
    , showDraftStatus
    )

import DateFormat
import Html exposing (Html)
import Html.Attributes as Attrs
import Models exposing (TimeZone)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Time exposing (Posix, Zone, ZoneName(..))


type alias DateTitleHrefRecord =
    { date : Posix
    , title : String
    , href : String
    }


showDraftStatus : Bool -> Html.Html Msg
showDraftStatus is_draft =
    case is_draft of
        True ->
            Html.span [ Attrs.class "meeting-draft" ]
                [ Html.text "[draft]" ]

        False ->
            Html.text ""


dateTitleHrefRow : TimeZone -> DateTitleHrefRecord -> Html Msg
dateTitleHrefRow timeZone dth =
    Html.div [ Attrs.class "clearfix mb2" ]
        [ Html.time [ Attrs.class "left p1 mr1 classdate" ]
            [ Html.div [] [ Html.text (shortDayOfWeek dth.date timeZone.zone) ]
            , Html.div [] [ Html.text (shortDateMonth dth.date timeZone.zone) ]
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


shortDayOfWeek : Posix -> Zone -> String
shortDayOfWeek t z =
    DateFormat.format [ DateFormat.dayOfWeekNameAbbreviated ] z t


shortDateMonth : Posix -> Zone -> String
shortDateMonth t z =
    DateFormat.format [ DateFormat.dayOfMonthFixed, DateFormat.monthNameAbbreviated ] z t


longDateFormatter : TimeZone -> Posix -> String
longDateFormatter timeZone =
    let
        name =
            case timeZone.zoneName of
                Name theName ->
                    theName

                Offset offset ->
                    "an offset"
    in
    DateFormat.format
        [ DateFormat.hourFixed
        , DateFormat.text ":"
        , DateFormat.minuteFixed
        , DateFormat.amPmLowercase
        , DateFormat.text " "
        , DateFormat.dayOfWeekNameFull
        , DateFormat.text (" (" ++ name ++ "), ")
        , DateFormat.monthNameFull
        , DateFormat.text " "
        , DateFormat.dayOfMonthNumber
        , DateFormat.text ", "
        , DateFormat.yearNumber
        ]
        timeZone.zone


{-| Format a date like Wed 09May
-}
shortDateFormatter : Zone -> Posix -> String
shortDateFormatter =
    DateFormat.format
        [ DateFormat.dayOfWeekNameAbbreviated
        , DateFormat.text " "
        , DateFormat.dayOfMonthFixed
        , DateFormat.monthNameAbbreviated
        ]


{-| Format a Posix time like "2018-05-20T19:18:24.911Z"
-}
longDateToString : Posix -> TimeZone -> String
longDateToString t z =
    longDateFormatter z t


shortDateToString : Posix -> TimeZone -> String
shortDateToString t z =
    -- DateFormat.format "%a %d%b" date
    shortDateFormatter z.zone t


{-| Format the time zone name. See
<https://discourse.elm-lang.org/t/how-to-get-a-zone-name-from-the-time-package/2180/4>
-}
formatZoneName : Time.ZoneName -> String
formatZoneName zoneName =
    case zoneName of
        Time.Name n ->
            n

        Time.Offset 0 ->
            "UTC"

        Time.Offset o ->
            let
                sign =
                    case o > 0 of
                        True ->
                            "+"

                        False ->
                            "-"

                numMinutes =
                    abs o

                hours =
                    String.fromInt (numMinutes // 60)

                minutes =
                    modBy 60 numMinutes

                minSuffix =
                    case minutes == 0 of
                        True ->
                            ""

                        False ->
                            ":" ++ String.fromInt minutes
            in
            "UTC " ++ sign ++ hours ++ minSuffix
