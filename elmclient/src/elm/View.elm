module View exposing (..)

import Assignments.Views
import Auth.Views
import Common.Views exposing (piazzaLink)
import Html exposing (Html, a, div, h1, text)
import Html.Attributes exposing (href)
import Meetings.Views
import Models exposing (Model)
import Msgs exposing (Msg)
import Quizzes.Views


view : Model -> Html Msg
view model =
    div []
        [ div [] [ page model ]
        ]


page : Model -> Html Msg
page model =
    case model.route of
        Models.IndexRoute ->
            indexView model

        Models.CurrentUserDashboardRoute ->
            Auth.Views.dashboard model.currentUser

        Models.MeetingListRoute ->
            Meetings.Views.listView model.meetings

        Models.MeetingDetailRoute slug ->
            Meetings.Views.detailView model.currentUser model.meetings slug model.quizzes model.quizSubmissions model.pendingBeginQuizzes

        Models.AssignmentListRoute ->
            Assignments.Views.listView model.assignments

        Models.AssignmentDetailRoute slug ->
            Assignments.Views.detailView model.assignments model.assignmentSubmissions model.pendingBeginAssignments slug model.current_date

        Models.TakeQuizRoute quizSubmissionID ->
            Quizzes.Views.takeQuizView quizSubmissionID model.quizSubmissions model.quizzes

        Models.NotFoundRoute ->
            notFoundView


indexView : Model -> Html Msg
indexView model =
    div []
        [ h1 [] [ text model.uiElements.courseTitle ]
        , div [] [ a [ href "https://github.com/yale-cpsc-213-spring-2018/about-this-class" ] [ text "About" ] ]
        , div [] [ a [ href "#/meetings" ] [ text "Meetings" ] ]
        , div [] [ a [ href "#/assignments" ] [ text "Assignments" ] ]
        , piazzaLink model.uiElements.piazzaURL
        , div [] [ a [ href "/openapi/" ] [ text "API" ] ]
        , div [] [ Auth.Views.loginOrDashboard model.currentUser ]
        ]


notFoundView : Html msg
notFoundView =
    div []
        [ text "Not found"
        ]
