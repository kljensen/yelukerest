module Assignments.Views exposing (detailView, listView)

import Assignments.Model exposing (Assignment, AssignmentField, AssignmentSlug)
import Auth.Views
import Common.Views
import Date exposing (Date)
import Date.Format as DateFormat
import Html exposing (Html, a, div, h1, text)
import Html.Attributes as Attrs
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


detailView : WebData (List Assignment) -> AssignmentSlug -> Maybe Date -> Html.Html Msg
detailView assignments slug current_date =
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
                    detailViewForJustAssignment assignment current_date

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
    DateFormat.format "%l:%M%p %A, %B %e" date



-- TODO: hide the form when the client knows the closed_at date is passed.


detailViewForJustAssignment : Assignment -> Maybe Date -> Html.Html Msg
detailViewForJustAssignment assignment current_date =
    Html.div []
        [ Html.h1 [] [ Html.text assignment.title, Common.Views.showDraftStatus assignment.is_draft ]
        , Html.div []
            [ Html.text "Due: "
            , Html.time [] [ Html.text (dateTimeToString assignment.closed_at) ]
            ]
        , Markdown.toHtml [] assignment.body
        , case current_date of
            Just d ->
                Html.div []
                    [ Html.h3 [] [ Html.text "How to submit" ]
                    , submissionInstructions assignment d
                    ]

            Nothing ->
                Html.text ""
        ]


submissionInstructions : Assignment -> Date -> Html.Html Msg
submissionInstructions assignment current_date =
    case assignment.is_open of
        True ->
            showSubmissionForm assignment

        False ->
            case assignment.is_draft of
                True ->
                    Html.div [] [ Html.text "This assignment is in draft mode and cannot yet be submitted." ]

                False ->
                    Html.div [] [ Html.text "This assignment will not accept new submissions because it is past due." ]


showSubmissionForm : Assignment -> Html.Html Msg
showSubmissionForm assignment =
    Html.form [] (List.map showFormField assignment.fields ++ [ Html.button [ Attrs.class "btn btn-primary" ] [ Html.text "Submit" ] ])


showFormField : AssignmentField -> Html.Html Msg
showFormField assignmentField =
    let
        fieldType =
            if assignmentField.is_url then
                "url"
            else
                "text"
    in
    Html.div []
        [ Html.label [] [ Html.text assignmentField.label ]
        , case assignmentField.is_multiline of
            True ->
                Html.textarea
                    [ Attrs.class "textarea"
                    , Attrs.placeholder assignmentField.placeholder
                    , Attrs.name (toString assignmentField.id)
                    ]
                    []

            False ->
                Html.input
                    [ Attrs.type_ fieldType
                    , Attrs.class "input field"
                    , Attrs.placeholder assignmentField.placeholder
                    , Attrs.title assignmentField.help
                    , Attrs.name (toString assignmentField.id)
                    ]
                    []
        ]
