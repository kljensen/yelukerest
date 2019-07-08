module Meetings.Views exposing (detailView, listView)

import Auth.Model exposing (CurrentUser, isLoggedInFacultyOrTA)
import Common.Views exposing (longDateToString)
import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes as Attrs
import Html.Events as Events
import Markdown
import Meetings.Model exposing (Meeting, MeetingSlug)
import Models exposing (TimeZone)
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
import Time exposing (Posix)


listView : TimeZone -> WebData (List Meeting) -> Html Msg
listView timeZone meetings =
    Html.div [] [ listOrStatus timeZone meetings ]



-- getQuizForMeeting


getQuizForMeetingSlug : String -> WebData (List Quiz) -> Maybe Quiz
getQuizForMeetingSlug slug wdQuizzes =
    case wdQuizzes of
        RemoteData.Success quizzes ->
            quizzes
                |> List.filter (\quiz -> quiz.meeting_slug == slug)
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


detailView : Maybe Posix -> TimeZone -> WebData CurrentUser -> WebData (List Meeting) -> MeetingSlug -> WebData (List Quiz) -> WebData (List QuizSubmission) -> Dict Int (WebData (List QuizSubmission)) -> Html.Html Msg
detailView maybeCurrentDate timeZone currentUser wdMeetings slug quizzes quizSubmissions pendingBeginQuizzes =
    case maybeCurrentDate of
        Nothing ->
            Html.text "Loding..."

        Just currentDate ->
            case wdMeetings of
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
                            detailViewForJustMeeting currentDate timeZone currentUser meeting quizzes quizSubmissions pendingBeginQuizzes

                        Nothing ->
                            meetingNotFoundView slug

                RemoteData.Failure err ->
                    Html.text "Error loading meetings!"


detailViewForJustMeeting : Posix -> TimeZone -> WebData CurrentUser -> Meeting -> WebData (List Quiz) -> WebData (List QuizSubmission) -> Dict Int (WebData (List QuizSubmission)) -> Html.Html Msg
detailViewForJustMeeting currentDate timeZone currentUser meeting wdQuizzes wdQuizSubmissions pendingBeginQuizzes =
    let
        maybeQuiz =
            getQuizForMeetingSlug meeting.slug wdQuizzes

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
            [ Html.time [] [ Html.text (longDateToString meeting.begins_at timeZone) ]
            ]
        , Markdown.toHtml [] meeting.description
        , case currentUser of
            RemoteData.Success user ->
                showQuizStatus currentDate timeZone meeting wdQuizzes wdQuizSubmissions maybePendingBeginQuiz

            _ ->
                Html.div [] [ Html.text "You must log in to see quiz information for this meeting." ]
        , recordEngagementButton meeting.slug currentUser
        ]


recordEngagementButton : String -> WebData CurrentUser -> Html.Html Msg
recordEngagementButton meetingSlug currentUser =
    case isLoggedInFacultyOrTA currentUser of
        Ok _ ->
            Html.a [ Attrs.href ("#/engagements/" ++ meetingSlug) ]
                [ Html.button
                    [ Attrs.class "btn btn-primary" ]
                    [ Html.text "Take attendance" ]
                ]

        _ ->
            Html.text ""


showQuizStatus : Posix -> TimeZone -> Meeting -> WebData (List Quiz) -> WebData (List QuizSubmission) -> Maybe (WebData (List QuizSubmission)) -> Html.Html Msg
showQuizStatus currentDate timeZone meeting wdQuizzes wdQuizSubmissions maybePendingBeginQuiz =
    case wdQuizzes of
        RemoteData.Success quizzes ->
            let
                maybeQuiz =
                    quizzes
                        |> List.filter (\quiz -> quiz.meeting_slug == meeting.slug)
                        |> List.head
            in
            case maybeQuiz of
                Just quiz ->
                    Html.p []
                        [ showQuizSubmissionStatus currentDate timeZone quiz wdQuizSubmissions maybePendingBeginQuiz
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


showQuizSubmissionStatus : Posix -> TimeZone -> Quiz -> WebData (List QuizSubmission) -> Maybe (WebData (List QuizSubmission)) -> Html.Html Msg
showQuizSubmissionStatus currentDate timeZone quiz wdQuizSubmissions maybePendingBeginQuiz =
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
                    pText ("This quiz is now closed. It was due by " ++ longDateToString quiz.closed_at timeZone ++ ".")

                ( QuizIsDraft, _ ) ->
                    pText "This quiz is still in draft mode. The instructor needs to finize the quiz."

                ( BeforeQuizOpen, _ ) ->
                    pText ("This quiz is not yet open for submissions. It opens at " ++ longDateToString quiz.open_at timeZone ++ ".")

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


listOrStatus : TimeZone -> WebData (List Meeting) -> Html Msg
listOrStatus timeZone wdMeetings =
    case wdMeetings of
        RemoteData.NotAsked ->
            Html.text ""

        RemoteData.Loading ->
            Html.text "Loading..."

        RemoteData.Success meetings ->
            listMeetings timeZone meetings

        RemoteData.Failure error ->
            Html.text "HTTP Error!"


listMeetings : TimeZone -> List Meeting -> Html Msg
listMeetings timeZone meetings =
    let
        meetingDetails =
            List.map (\m -> { date = m.begins_at, title = m.title, href = "#meetings/" ++ m.slug }) meetings
    in
    Html.div [] (List.map (Common.Views.dateTitleHrefRow timeZone) meetingDetails)
