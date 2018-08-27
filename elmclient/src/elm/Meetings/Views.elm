module Meetings.Views exposing (detailView, listView)

import Auth.Model exposing (CurrentUser, isLoggedInFacultyOrTA)
import Common.Views exposing (dateToString)
import Date
import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes as Attrs
import Html.Events as Events
import Markdown
import Meetings.Model exposing (Meeting, MeetingSlug)
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( Quiz
        , QuizOpenState(..)
        , QuizSubmission
        , SubmissionEditableState(..)
        , quizSubmitability
        )
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


detailView : Maybe Date.Date -> WebData CurrentUser -> WebData (List Meeting) -> MeetingSlug -> WebData (List Quiz) -> WebData (List QuizSubmission) -> Dict Int (WebData (List QuizSubmission)) -> Html.Html Msg
detailView maybeCurrentDate currentUser meetings slug quizzes quizSubmissions pendingBeginQuizzes =
    case maybeCurrentDate of
        Nothing ->
            Html.text "Loding..."

        Just currentDate ->
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
                            detailViewForJustMeeting currentDate currentUser meeting quizzes quizSubmissions pendingBeginQuizzes

                        Nothing ->
                            meetingNotFoundView slug

                RemoteData.Failure err ->
                    Html.text (toString err)


detailViewForJustMeeting : Date.Date -> WebData CurrentUser -> Meeting -> WebData (List Quiz) -> WebData (List QuizSubmission) -> Dict Int (WebData (List QuizSubmission)) -> Html.Html Msg
detailViewForJustMeeting currentDate currentUser meeting wdQuizzes wdQuizSubmissions pendingBeginQuizzes =
    let
        maybeQuiz =
            getQuizForMeetingID meeting.id wdQuizzes

        maybeQuizSubmission =
            getQuizSubmissionForQuizID meeting.id wdQuizSubmissions

        maybePendingBeginQuiz =
            case maybeQuiz of
                Just quiz ->
                    Dict.get quiz.id pendingBeginQuizzes

                _ ->
                    Nothing
    in
    Html.div []
        [ Html.h1 [] [ Html.text meeting.title, Common.Views.showDraftStatus meeting.is_draft ]
        , Html.p []
            [ Html.time [] [ Html.text (dateToString meeting.begins_at) ]
            ]
        , Markdown.toHtml [] meeting.description
        , case currentUser of
            RemoteData.Success user ->
                showQuizStatus currentDate meeting wdQuizzes wdQuizSubmissions maybePendingBeginQuiz

            _ ->
                Html.div [] [ Html.text "You must log in to see quiz information for this meeting." ]
        , recordEngagementButton meeting.id currentUser
        ]


recordEngagementButton : Int -> WebData CurrentUser -> Html.Html Msg
recordEngagementButton meetingID currentUser =
    case isLoggedInFacultyOrTA currentUser of
        Ok _ ->
            Html.a [ Attrs.href ("#/engagements/" ++ toString meetingID) ]
                [ Html.button
                    [ Attrs.class "btn btn-primary" ]
                    [ Html.text "Take attendance" ]
                ]

        _ ->
            Html.text ""


showQuizStatus : Date.Date -> Meeting -> WebData (List Quiz) -> WebData (List QuizSubmission) -> Maybe (WebData (List QuizSubmission)) -> Html.Html Msg
showQuizStatus currentDate meeting wdQuizzes wdQuizSubmissions maybePendingBeginQuiz =
    case wdQuizzes of
        RemoteData.Success quizzes ->
            let
                maybeQuiz =
                    quizzes
                        |> List.filter (\quiz -> quiz.meeting_id == meeting.id)
                        |> List.head
            in
            case maybeQuiz of
                Just quiz ->
                    let
                        quizMsg =
                            case quiz.is_open of
                                True ->
                                    "There is a quiz for this meeting and it is open for submission until" ++ dateToString quiz.closed_at ++ "."

                                False ->
                                    "There is a quiz for this meeting but it is not open for submission. You must submit it between" ++ dateToString quiz.open_at ++ " and " ++ dateToString quiz.closed_at ++ "."
                    in
                    Html.p []
                        [ Html.text quizMsg
                        , showQuizSubmissionStatus currentDate quiz wdQuizSubmissions maybePendingBeginQuiz
                        ]

                Nothing ->
                    if meeting.is_draft then
                        Html.p [] [ Html.text "Unless this is a \"special\" class, like an exam, there will likely be a quiz. The class is still labeled \"draft\" and the quiz information cannot be loaded at this time." ]
                    else
                        Html.p [] [ Html.text "There is no quiz for this meeting." ]

        RemoteData.NotAsked ->
            Html.text "Quizzes not yet loaded. Unclear if there is a quiz for this meeting."

        RemoteData.Loading ->
            Html.text "Loading quizzes."

        RemoteData.Failure error ->
            Html.text "Failed to load quizzes!"


pText : String -> Html.Html Msg
pText theString =
    Html.p [] [ Html.text theString ]


showQuizSubmissionStatus : Date.Date -> Quiz -> WebData (List QuizSubmission) -> Maybe (WebData (List QuizSubmission)) -> Html.Html Msg
showQuizSubmissionStatus currentDate quiz wdQuizSubmissions maybePendingBeginQuiz =
    case wdQuizSubmissions of
        RemoteData.Success submissions ->
            let
                maybeSubmission =
                    submissions
                        |> List.filter (\qs -> qs.quiz_id == quiz.id)
                        |> List.head

                submitablity =
                    quizSubmitability currentDate quiz maybeSubmission
            in
            case submitablity of
                ( QuizOpen, EditableSubmission submission ) ->
                    Html.div []
                        [ Html.p [] [ Html.text "You already started the quiz." ]
                        , Html.p []
                            [ Html.button
                                [ Attrs.class "btn btn-primary"
                                , Events.onClick (Msgs.TakeQuiz quiz.id)
                                ]
                                [ Html.text "Re-start quiz" ]
                            ]
                        ]

                ( QuizOpen, NoSubmission ) ->
                    let
                        defaultAttrs =
                            [ Attrs.class "btn btn-primary" ]

                        ( btnText, btnAttrs ) =
                            case maybePendingBeginQuiz of
                                Nothing ->
                                    ( "Begin quiz", defaultAttrs ++ [ Events.onClick (Msgs.OnBeginQuiz quiz.id) ] )

                                _ ->
                                    ( "Begin quiz", defaultAttrs ++ [ Attrs.disabled True ] )
                    in
                    Html.div []
                        [ Html.p [] [ Html.text "You did not yet start the quiz." ]
                        , Html.p [] [ Html.button btnAttrs [ Html.text btnText ] ]
                        ]

                ( _, NotEditableSubmission submission ) ->
                    Html.p []
                        [ Html.text "You already submitted this quiz."
                        ]

                ( AfterQuizClosed, _ ) ->
                    pText ("This quiz is now closed. It was due by " ++ dateToString quiz.closed_at ++ ".")

                ( BeforeQuizOpen, _ ) ->
                    pText ("This quiz is not yet open for submissions. It opens at " ++ dateToString quiz.open_at ++ ".")

        RemoteData.NotAsked ->
            pText "Quiz submissions not yet loaded. Unclear if you started this quiz."

        RemoteData.Loading ->
            pText "Loading quiz submissions."

        RemoteData.Failure error ->
            pText "Failed to load quiz submissions!"


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
