module Meetings.Views exposing (detailView, listView)

import Common.Views
import Date
import Date.Format as DateFormat
import Html exposing (Html)
import Markdown
import Meetings.Model exposing (Meeting, MeetingSlug)
import Msgs exposing (Msg)
import Quizzes.Model exposing (Quiz, QuizSubmission)
import RemoteData exposing (WebData)


listView : WebData (List Meeting) -> Html Msg
listView meetings =
    Html.div [] [ listOrStatus meetings ]



-- getQuizForMeeting


getQuizForMeetingID : Int -> WebData (List Quiz) -> Maybe Quiz
getQuizForMeetingID meetingID quizzes =
    case quizzes of
        RemoteData.Success quizzes ->
            quizzes
                |> List.filter (\quiz -> quiz.meeting_id == meetingID)
                |> List.head

        _ ->
            Nothing


webDataToMaybe : WebData a -> Maybe a
webDataToMaybe wdval =
    case wdval of
        RemoteData.Success val ->
            Just val

        _ ->
            Nothing


getQuizSubmissionForQuizID : Int -> WebData (List QuizSubmission) -> Maybe QuizSubmission
getQuizSubmissionForQuizID quizID wdQuizSubmissionList =
    case wdQuizSubmissionList of
        RemoteData.Success submissions ->
            submissions
                |> List.filter (\qs -> qs.quiz_id == quizID)
                |> List.head

        _ ->
            Nothing


detailView : WebData (List Meeting) -> MeetingSlug -> WebData (List Quiz) -> WebData (List QuizSubmission) -> Html.Html Msg
detailView meetings slug quizzes quizSubmissions =
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
                    detailViewForJustMeeting meeting quizzes quizSubmissions

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


detailViewForJustMeeting : Meeting -> WebData (List Quiz) -> WebData (List QuizSubmission) -> Html.Html Msg
detailViewForJustMeeting meeting wdQuizzes wdQuizSubmissions =
    let
        maybeQuiz =
            getQuizForMeetingID meeting.id wdQuizzes

        maybeQuizSubmission =
            getQuizSubmissionForQuizID meeting.id wdQuizSubmissions
    in
    Html.div []
        [ Html.h1 [] [ Html.text meeting.title, Common.Views.showDraftStatus meeting.is_draft ]
        , Html.div []
            [ Html.time [] [ Html.text (dateToString meeting.begins_at) ]
            ]
        , Markdown.toHtml [] meeting.description
        , showQuizStatus maybeQuiz
        , showQuizSubmissionStatus maybeQuizSubmission
        ]


showQuizStatus : Maybe Quiz -> Html.Html msg
showQuizStatus maybeQuiz =
    case maybeQuiz of
        Just quiz ->
            Html.div [] [ Html.text "There is a quiz for this meeting." ]

        Nothing ->
            Html.div [] [ Html.text "There is no quiz for this meeting." ]


showQuizSubmissionStatus : Maybe QuizSubmission -> Html.Html msg
showQuizSubmissionStatus maybeQuizSubmission =
    case maybeQuizSubmission of
        Just qs ->
            Html.div [] [ Html.text "There is already a submission for this quiz." ]

        Nothing ->
            Html.div [] [ Html.text "There NO submission for this quiz." ]


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
