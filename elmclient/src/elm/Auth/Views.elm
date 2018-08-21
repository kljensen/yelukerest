module Auth.Views exposing (dashboard, loginLink, loginOrDashboard)

import Auth.Model exposing (CurrentUser)
import Html exposing (Html)
import Html.Attributes as Attrs
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


loginLink : Html.Html Msg
loginLink =
    Html.a [ Attrs.href "/auth/login" ] [ Html.text "Login" ]


loginOrDashboard : WebData CurrentUser -> Html.Html Msg
loginOrDashboard currentUser =
    case currentUser of
        RemoteData.NotAsked ->
            Html.text ""

        RemoteData.Loading ->
            loginLink

        RemoteData.Success currentUser ->
            Html.a
                [ Attrs.href "#/dashboard" ]
                [ Html.text "Dashboard" ]

        RemoteData.Failure err ->
            loginLink


dashboard : WebData CurrentUser -> Html.Html Msg
dashboard currentUser =
    case currentUser of
        RemoteData.NotAsked ->
            Html.text ""

        RemoteData.Loading ->
            Html.text "Loading ..."

        RemoteData.Success currentUser ->
            showDashboard currentUser

        RemoteData.Failure err ->
            loginLink


showDashboard : CurrentUser -> Html.Html Msg
showDashboard currentUser =
    Html.table
        []
        [ Html.tbody []
            [   dashboardRow "id" (toString currentUser.id)
            , dashboardRow "netid" currentUser.netid
            , dashboardRow "role" currentUser.role
            , dashboardRow "nickname" currentUser.nickname
            , dashboardRow "team_nickname" (Maybe.withDefault "none" currentUser.team_nickname )
            , dashboardRow "jwt" currentUser.jwt
            ]
        ]

dashboardRow : String -> String -> Html.Html Msg
dashboardRow label value =
    Html.tr []
        [ Html.td [] [ Html.text label ]
        , Html.td [] [ Html.text value ]
        ]