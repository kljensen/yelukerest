module View exposing (indexView, notFoundView, page, view)

import Assignments.Views
import Auth.Model exposing (CurrentUser)
import Auth.Views
import Browser exposing (Document)
import Common.Views exposing (piazzaLink, slackLink)
import Dashboard.Views
import Engagements.Views exposing (maybeEditEngagements)
import Html exposing (Html, a, div, h1, text)
import Html.Attributes exposing (href)
import Html.Lazy exposing (lazy2, lazy5, lazy6)
import Meetings.Views
import Models exposing (Model, UIElements)
import Msgs exposing (Msg)
import Quizzes.Views
import RemoteData exposing (WebData)


view : Model -> Document Msg
view model =
    let
        content =
            div [] [ div [] [ page model ] ]
    in
    Document model.uiElements.courseTitle [ content ]


page : Model -> Html Msg
page model =
    case model.route of
        Models.IndexRoute ->
            lazy2 indexView model.currentUser model.uiElements

        Models.CurrentUserDashboardRoute ->
            Dashboard.Views.dashboard model

        Models.MeetingListRoute ->
            lazy2 Meetings.Views.listView model.timeZone model.meetings

        Models.MeetingDetailRoute slug ->
            Meetings.Views.detailView model.current_date model.timeZone model.currentUser model.meetings slug model.quizzes model.quizSubmissions model.quizGradeExceptions model.pendingBeginQuizzes

        Models.AssignmentListRoute ->
            lazy2 Assignments.Views.listView model.timeZone model.assignments

        Models.AssignmentDetailRoute slug ->
            Assignments.Views.detailView model.currentUser model.current_date model.timeZone model.assignments model.assignmentSubmissions model.assignmentGradeExceptions model.pendingBeginAssignments slug model.current_date
        
        Models.AssignmentGradeDetailRoute slug ->
            Assignments.Views.gradeView model.assignmentGrades model.assignmentSubmissions slug model.currentUser

        Models.TakeQuizRoute quizID ->
            Quizzes.Views.takeQuizView model.currentUser model.current_date model.timeZone quizID model.quizSubmissions model.quizzes model.quizQuestions model.quizAnswers model.quizGradeExceptions model.pendingSubmitQuizzes model.quizQuestionOptionInputs

        Models.EditEngagementsRoute meetingSlug ->
            lazy6 maybeEditEngagements model.currentUser model.engagementUserQuery model.users model.engagements model.meetings meetingSlug

        Models.NotFoundRoute ->
            notFoundView


indexView : WebData CurrentUser -> UIElements -> Html Msg
indexView currentUser uiElements =
    div []
        [ h1 [] [ text uiElements.courseTitle ]
        , div [] [ a [ href uiElements.aboutURL ] [ text "About" ] ]
        , div [] [ a [ href "#/meetings" ] [ text "Meetings" ] ]
        , div [] [ a [ href "#/assignments" ] [ text "Assignments" ] ]
        , div [] [ Html.a [ href uiElements.canvasURL ] [ Html.text "Canvas" ] ]
        , piazzaLink uiElements.piazzaURL
        , slackLink uiElements.slackURL
        , div [] [ a [ href "/openapi/" ] [ text "API" ] ]
        , div [] [ Auth.Views.loginOrDashboard currentUser ]
        ]


notFoundView : Html msg
notFoundView =
    div []
        [ text "Not found"
        ]
