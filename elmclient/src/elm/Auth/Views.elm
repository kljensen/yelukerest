module Auth.Views exposing (dashboard, nameOrDashboard)

import Auth.Model exposing (CurrentUser)
import Html exposing (Html)
import Html.Attributes as Attrs
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


nameOrDashboard : WebData CurrentUser -> Html.Html Msg
nameOrDashboard currentUser =
    case currentUser of
        RemoteData.NotAsked ->
            Html.text ""

        RemoteData.Loading ->
            Html.text "Loading ..."

        RemoteData.Success currentUser ->
            Html.a
                [ Attrs.href "#/dashboard" ]
                [ Html.text "Dashboard" ]

        RemoteData.Failure err ->
            Html.text (toString err)


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
            Html.text (toString err)


showDashboard : CurrentUser -> Html.Html Msg
showDashboard currentUser =
    Html.table
        []
        [ Html.tbody []
            [ Html.tr []
                [ Html.td [] [ Html.text "id" ]
                , Html.td [] [ Html.text (toString currentUser.id) ]
                ]
            , Html.tr []
                [ Html.td [] [ Html.text "netid" ]
                , Html.td [] [ Html.text currentUser.netid ]
                ]
            ]
        ]
