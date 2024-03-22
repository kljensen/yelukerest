module Common.Views exposing
    ( DateTitleHrefRecord
    , dateDeltaToString
    , dateTitleHrefRow
    , divWithText
    , longDateToString
    , piazzaLink
    , shortDateToString
    , showDraftStatus
    , slackLink
    , stringDateDelta
    )

import DateFormat
import Html exposing (Html)
import Html.Attributes as Attrs
import Models exposing (TimeZone)
import Msgs exposing (Msg)
import Time exposing (Posix, Zone, ZoneName(..))
import Assignments.Model exposing (NotSubmissibleReason(..))


type alias DateTitleHrefRecord =
    { date : Posix
    , title : String
    , href : String
    , isDraft : Bool
    }


showDraftStatus : Bool -> Html.Html Msg
showDraftStatus is_draft =
    if is_draft then
        Html.span [ Attrs.class "meeting-draft" ]
            [ Html.text "[draft]" ]
    else
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
            , showDraftStatus dth.isDraft
            ]
        ]


divWithText : String -> Html Msg
divWithText theText =
    Html.div [] [ Html.text theText ]


piazzaLink : Maybe String -> Html Msg
piazzaLink piazzaURL =
    maybeLink piazzaURL "Piazza"

slackLink : Maybe String -> Html Msg
slackLink slackURL =
    maybeLink slackURL "Slack"

maybeLink : Maybe String -> String -> Html Msg
maybeLink theURL theText =
    case theURL of
        Just url ->
            case url of 
                "" ->
                    Html.text ""
                _  ->
                    Html.a [ Attrs.href url ] [ Html.text theText ]

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

                Offset _ ->
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

dateDelta : Posix -> Posix -> Int
dateDelta d2 d1 =
    Time.posixToMillis d2 - Time.posixToMillis d1


stringDateDelta : Posix -> Posix -> String
stringDateDelta d2 d1 =
    dateDeltaToString (dateDelta d2 d1)


dateDeltaToString : Int -> String
dateDeltaToString d =
    let
        msInSecond =
            1000

        msInMinute =
            60 * msInSecond

        msInHour =
            60 * msInMinute

        msInDay =
            24 * msInHour

        days =
            d // msInDay

        d2 =
            d - (days * msInDay)

        hours =
            d2 // msInHour

        d3 =
            d2 - (hours * msInHour)

        minutes =
            d3 // msInMinute

        d4 =
            d3 - (minutes * msInMinute)

        seconds =
            d4 // msInSecond
    in
    if days > 0 then
        String.fromInt days
            ++ " days and "
            ++ String.fromInt hours
            ++ " hours"
    else
        [ hours, minutes, seconds ]
            |> List.map String.fromInt
            |> List.map (String.padLeft 2 '0')
            |> String.join ":"
