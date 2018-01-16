module Assignments.Views exposing (listView)

import Assignments.Model exposing (Assignment)
import Auth.Views
import Common.Views
import Html exposing (Html, a, div, h1, text)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


listView : WebData (List Assignment) -> Html Msg
listView assignments =
    case assignments of
        RemoteData.NotAsked ->
            loginToViewAssignments

        RemoteData.Loading ->
            Html.text "Loading..."

        RemoteData.Success assignments ->
            listAssignments assignments

        RemoteData.Failure error ->
            loginToViewAssignments


loginToViewAssignments : Html Msg
loginToViewAssignments =
    Html.div []
        [ div []
            [ Html.text "Either there was an error or you are not permited to view assignments." ]
        , div
            []
            [ Auth.Views.loginLink ]
        ]


listAssignments : List Assignment -> Html Msg
listAssignments assignments =
    let
        assignmentDetails =
            List.map (\a -> { date = a.closed_at, title = a.title, href = "#assignments/" ++ a.slug }) assignments
    in
    Html.div [] (List.map Common.Views.dateTitleHrefRow assignmentDetails)
