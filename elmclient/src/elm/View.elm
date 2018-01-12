module View exposing (..)

import Auth.Views
import Html exposing (Html, a, div, h1, text)
import Html.Attributes exposing (href)
import Meetings.Views
import Models exposing (Model)
import Msgs exposing (Msg)
import Players.Edit
import Players.List
import Players.Model exposing (PlayerId)
import RemoteData


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
            Meetings.Views.detailView model.meetings slug

        Models.PlayersRoute ->
            Players.List.view model.players

        Models.PlayerRoute id ->
            playerEditPage model id

        Models.NotFoundRoute ->
            notFoundView


indexView : Model -> Html Msg
indexView model =
    div []
        [ h1 [] [ text "Classname" ]
        , div [] [ text "About" ]
        , div [] [ a [ href "#/meetings" ] [ text "Meetings" ] ]
        , div [] [ text "Assignments" ]
        , div [] [ Auth.Views.loginOrDashboard model.currentUser ]
        ]


playerEditPage : Model -> PlayerId -> Html Msg
playerEditPage model playerId =
    case model.players of
        RemoteData.NotAsked ->
            text ""

        RemoteData.Loading ->
            text "Loading ..."

        RemoteData.Success players ->
            let
                maybePlayer =
                    players
                        |> List.filter (\player -> player.id == playerId)
                        |> List.head
            in
            case maybePlayer of
                Just player ->
                    Players.Edit.view player

                Nothing ->
                    notFoundView

        RemoteData.Failure err ->
            text (toString err)


notFoundView : Html msg
notFoundView =
    div []
        [ text "Not found"
        ]
