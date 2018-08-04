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
        , showQuizStatus meeting.id wdQuizzes wdQuizSubmissions
        ]


showQuizStatus : Int -> WebData (List Quiz) -> WebData (List QuizSubmission) -> Html.Html msg
showQuizStatus meetingID wdQuizzes wdQuizSubmissions =
    case wdQuizzes of
        RemoteData.Success quizzes ->
            let
                maybeQuiz =
                    quizzes
                        |> List.filter (\quiz -> quiz.meeting_id == meetingID)
                        |> List.head
            in
            case maybeQuiz of
                Just quiz ->
                    Html.div []
                        [ Html.text "There is a quiz for this meeting."
                        , showQuizSubmissionStatus quiz.id wdQuizSubmissions
                        ]

                Nothing ->
                    Html.div [] [ Html.text "There is no quiz for this meeting." ]

        RemoteData.NotAsked ->
            Html.text "Quizzes not yet loaded. Unclear if there is a quiz for this meeting."

        RemoteData.Loading ->
            Html.text "Loading quizzes."

        RemoteData.Failure error ->
            Html.text "Failed to load quizzes!"


showQuizSubmissionStatus : Int -> WebData (List QuizSubmission) -> Html.Html msg
showQuizSubmissionStatus quizID wdQuizSubmissions =
    case wdQuizSubmissions of
        RemoteData.Success submissions ->
            let
                maybeSubmission =
                    submissions
                        |> List.filter (\qs -> qs.quiz_id == quizID)
                        |> List.head
            in
            case maybeSubmission of
                Just submission ->
                    Html.div [] [ Html.text "You already started the quiz." ]

                Nothing ->
                    Html.div [] [ Html.text "You did not yet start the quiz." ]

        RemoteData.NotAsked ->
            Html.text "Quiz submissions not yet loaded. Unclear if you started this quiz."

        RemoteData.Loading ->
            Html.text "Loading quiz submissions."

        RemoteData.Failure error ->
            Html.text "Failed to load quiz submissions!"


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
