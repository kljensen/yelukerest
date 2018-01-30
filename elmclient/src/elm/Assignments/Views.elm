module Assignments.Views exposing (detailView, listView)

import Assignments.Model exposing (Assignment, AssignmentSlug)
import Auth.Views
import Common.Views
import Date
import Date.Format as DateFormat
import Html exposing (Html, a, div, h1, text)
import Markdown
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



-- TODO: refactor this---it duplicates a lot of code in the Meetings detail view.
-- in particular, we can generalize all the RemoteData logic into a shared function.


detailView : WebData (List Assignment) -> AssignmentSlug -> Html.Html Msg
detailView assignments slug =
    case assignments of
        RemoteData.NotAsked ->
            Html.text ""

        RemoteData.Loading ->
            Html.text "Loading ..."

        RemoteData.Success assignments ->
            let
                maybeAssignment =
                    assignments
                        |> List.filter (\assignment -> assignment.slug == slug)
                        |> List.head
            in
            case maybeAssignment of
                Just assignment ->
                    detailViewForJustAssignment assignment

                Nothing ->
                    meetingNotFoundView slug

        RemoteData.Failure err ->
            loginToViewAssignments


meetingNotFoundView : String -> Html msg
meetingNotFoundView slug =
    Html.div []
        [ Html.text ("No such class meeting" ++ slug)
        ]


dateTimeToString : Date.Date -> String
dateTimeToString date =
    DateFormat.format "%l%p %A, %B %e" date


detailViewForJustAssignment : Assignment -> Html.Html Msg
detailViewForJustAssignment assignment =
    Html.div []
        [ Html.h1 [] [ Html.text assignment.title, Common.Views.showDraftStatus assignment.is_draft ]
        , Html.div []
            [ Html.text "Due: "
            , Html.time [] [ Html.text (dateTimeToString assignment.closed_at) ]
            ]
        , Markdown.toHtml [] assignment.body
        ]
