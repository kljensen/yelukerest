module View exposing (indexView, notFoundView, page, view)

import Assignments.Views
import Auth.Model exposing (CurrentUser)
import Auth.Views
import Browser exposing (Document)
import ApiTokens.Views
import ConnectedApps.Views
import Dashboard.Views
import DataGrants.Views
import Engagements.Views exposing (maybeEditEngagements)
import Html exposing (Html, a, div, h1, text)
import Html.Attributes exposing (href)
import Html.Lazy exposing (lazy, lazy2, lazy3, lazy7)
import Mcp.Views
import Meetings.Views
import Models exposing (Model, UIElements)
import Msgs exposing (Msg)
import Pages.Model exposing (Pages)
import Pages.Views
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
            lazy3 indexView model.currentUser model.uiElements model.pages

        Models.AboutRoute ->
            lazy2 Pages.Views.aboutView notFoundView model.pages

        Models.CurrentUserDashboardRoute ->
            Dashboard.Views.dashboard model

        Models.MeetingListRoute ->
            lazy2 Meetings.Views.listView model.timeZone model.meetings

        Models.MeetingDetailRoute slug ->
            Meetings.Views.detailView model.timeZone model.currentUser model.meetings slug model.quizzes

        Models.AssignmentListRoute ->
            lazy2 Assignments.Views.listView model.timeZone model.assignments

        Models.AssignmentDetailRoute slug ->
            Assignments.Views.detailView model.currentUser model.current_date model.timeZone model.assignments model.assignmentSubmissions model.assignmentGradeExceptions model.pendingBeginAssignments model.pendingAssignmentFieldSubmissionRequests slug model.current_date
        
        Models.AssignmentGradeDetailRoute slug ->
            Assignments.Views.gradeView model.assignmentGrades model.assignmentSubmissions slug model.currentUser

        Models.EditEngagementsRoute meetingSlug ->
            lazy7 maybeEditEngagements model.currentUser model.engagementUserQuery model.users model.engagements model.meetings model.pendingSubmitEngagements meetingSlug

        Models.ConnectedAppsRoute ->
            ConnectedApps.Views.listView model.connectedApps model.pendingDisconnects

        Models.ApiTokensRoute ->
            ApiTokens.Views.listView
                model.apiTokens
                model.justCreatedApiToken
                model.apiTokenDraftName
                model.apiTokenDraftScopes
                model.pendingApiTokenRevokes

        Models.DataGrantsRoute ->
            DataGrants.Views.page model.timeZone.zone model

        Models.McpRoute ->
            lazy2 Mcp.Views.page model.uiElements.courseTitle model.uiElements.mcpEndpoint

        Models.NotFoundRoute ->
            notFoundView


indexView : WebData CurrentUser -> UIElements -> WebData Pages -> Html Msg
indexView currentUser uiElements pages =
    div []
        [ h1 [] [ text uiElements.courseTitle ]
        , if Pages.Views.hasAbout pages then
            div [] [ a [ href "#/about" ] [ text "About" ] ]

          else
            text ""
        , div [] [ a [ href "#/meetings" ] [ text "Meetings" ] ]
        , div [] [ a [ href "#/assignments" ] [ text "Assignments" ] ]
        , div [] [ a [ href "/openapi/" ] [ text "API" ] ]
        , div [] [ Auth.Views.loginOrDashboard currentUser ]
        ]


notFoundView : Html msg
notFoundView =
    div []
        [ text "Not found"
        ]
