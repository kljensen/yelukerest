module View exposing (indexView, notFoundView, page, view)

import Assignments.Views
import Auth.Views
import Browser exposing (Document)
import Common.Views exposing (piazzaLink)
import Dashboard.Views
import Engagements.Views exposing (maybeEditEngagements)
import Html exposing (Html, a, div, h1, text)
import Html.Attributes exposing (href)
import Meetings.Views
import Models exposing (Model)
import Msgs exposing (Msg)
import Quizzes.Views


view : Model -> Document Msg
view model =
    let
        content =
            div [] [ div [] [ page model ] ]
    in
    Document "foo" [ content ]


page : Model -> Html Msg
page model =
    case model.route of
        Models.IndexRoute ->
            indexView model

        Models.CurrentUserDashboardRoute ->
            Dashboard.Views.dashboard model

        Models.MeetingListRoute ->
            Meetings.Views.listView model.timeZone model.meetings

        Models.MeetingDetailRoute slug ->
            Meetings.Views.detailView model.current_date model.timeZone model.currentUser model.meetings slug model.quizzes model.quizSubmissions model.pendingBeginQuizzes

        Models.AssignmentListRoute ->
            Assignments.Views.listView model.timeZone model.assignments

        Models.AssignmentDetailRoute slug ->
            Assignments.Views.detailView model.currentUser model.current_date model.timeZone model.assignments model.assignmentSubmissions model.pendingBeginAssignments slug model.current_date

        Models.TakeQuizRoute quizID ->
            Quizzes.Views.takeQuizView model.current_date quizID model.quizSubmissions model.quizzes model.quizQuestions model.quizAnswers model.pendingSubmitQuizzes

        Models.EditEngagementsRoute meetingID ->
            maybeEditEngagements model.currentUser model.users model.engagements model.meetings meetingID

        Models.NotFoundRoute ->
            notFoundView


indexView : Model -> Html Msg
indexView model =
    div []
        [ h1 [] [ text model.uiElements.courseTitle ]
        , div [] [ a [ href model.uiElements.aboutURL ] [ text "About" ] ]
        , div [] [ a [ href "#/meetings" ] [ text "Meetings" ] ]
        , div [] [ a [ href "#/assignments" ] [ text "Assignments" ] ]
        , div [] [ Html.a [ href model.uiElements.canvasURL ] [ Html.text "Canvas" ] ]
        , piazzaLink model.uiElements.piazzaURL
        , div [] [ a [ href "/openapi/" ] [ text "API" ] ]
        , div [] [ Auth.Views.loginOrDashboard model.currentUser ]
        ]


notFoundView : Html msg
notFoundView =
    div []
        [ text "Not found"
        ]
