module Meetings.Views exposing (detailView, listView)

import Auth.Model exposing (CurrentUser, isLoggedInFacultyOrTA)
import Common.Views exposing (longDateToString)
import Html exposing (Html)
import Html.Attributes as Attrs
import Markdown exposing (toHtmlWith)
import Meetings.Model exposing (Meeting, MeetingSlug)
import Models exposing (TimeZone)
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( Quiz
        , paperQuizStatusText
        )
import RemoteData exposing (WebData)


markdownToHTML : List (Html.Attribute msg) -> String -> Html msg 
markdownToHTML attributes md =
    let 
        options = { githubFlavored = Just { tables = True, breaks = False }
            , defaultHighlighting = Nothing
            , sanitize = True
            , smartypants = False
            }
    in
    toHtmlWith options attributes md


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


detailView : TimeZone -> WebData CurrentUser -> WebData (List Meeting) -> MeetingSlug -> WebData (List Quiz) -> Html.Html Msg
detailView timeZone currentUser wdMeetings slug quizzes =
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
                    detailViewForJustMeeting timeZone currentUser meeting quizzes

                Nothing ->
                    meetingNotFoundView slug

        RemoteData.Failure _ ->
            Html.text "Error loading meetings!"


detailViewForJustMeeting : TimeZone -> WebData CurrentUser -> Meeting -> WebData (List Quiz) -> Html.Html Msg
detailViewForJustMeeting timeZone currentUser meeting wdQuizzes =
    Html.div []
        [ Html.h1 [] [ Html.text meeting.title, Common.Views.showDraftStatus meeting.is_draft ]
        , Html.p []
            [ Html.time [] [ Html.text (longDateToString meeting.begins_at timeZone) ]
            ]
        , markdownToHTML [] meeting.description
        , case currentUser of
            RemoteData.Success _ ->
                showQuizStatus meeting wdQuizzes

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


showQuizStatus : Meeting -> WebData (List Quiz) -> Html.Html Msg
showQuizStatus meeting wdQuizzes =
    case wdQuizzes of
        RemoteData.Success _ ->
            let
                maybeQuiz =
                    getQuizForMeetingSlug meeting.slug wdQuizzes
            in
            case maybeQuiz of
                Just _ ->
                    showPaperQuizStatus

                Nothing ->
                    if meeting.is_draft then
                        Html.p [] [ Html.text "Unless this is a \"special\" class, like an exam, there will likely be a quiz. The class is still labeled \"draft\" and the quiz information cannot be loaded at this time." ]

                    else
                        Html.p [] [ Html.text "There is no quiz for this meeting." ]

        RemoteData.NotAsked ->
            Html.text "Quizzes not yet loaded. Unclear if there is a quiz for this meeting."

        RemoteData.Loading ->
            Html.text "Loading quizzes."

        RemoteData.Failure _ ->
            Html.text "Failed to load quizzes!"


pText : String -> Html.Html Msg
pText theString =
    Html.p [] [ Html.text theString ]


showPaperQuizStatus : Html.Html Msg
showPaperQuizStatus =
    pText paperQuizStatusText


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

        RemoteData.Failure _ ->
            Html.text "HTTP Error!"


listMeetings : TimeZone -> List Meeting -> Html Msg
listMeetings timeZone meetings =
    let
        meetingDetails =
            List.map (\m -> {
                date = m.begins_at
                , title = m.title
                , href = "#meetings/" ++ m.slug
                , isDraft = m.is_draft
            }) meetings
    in
    Html.div [] (List.map (Common.Views.dateTitleHrefRow timeZone) meetingDetails)
