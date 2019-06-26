module Auth.Views exposing (loginLink, loginOrDashboard)

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

        RemoteData.Success u ->
            Html.a
                [ Attrs.href "#/dashboard" ]
                [ Html.text "Dashboard" ]

        RemoteData.Failure err ->
            loginLink
