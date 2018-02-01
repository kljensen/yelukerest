module Assignments.Views exposing (detailView, listView)

import Assignments.Model exposing (Assignment, AssignmentField, AssignmentFieldSubmission, AssignmentSlug, AssignmentSubmission)
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


getSubmissionForSlug : List AssignmentSubmission -> AssignmentSlug -> Maybe AssignmentSubmission
getSubmissionForSlug submissions slug =
    submissions
        |> List.filter (\submission -> submission.assignment_slug == slug)
        |> List.head



-- TODO: refactor this---it duplicates a lot of code in the Meetings detail view.
-- in particular, we can generalize all the RemoteData logic into a shared function.


detailView : WebData (List Assignment) -> WebData (List AssignmentSubmission) -> AssignmentSlug -> Maybe Date -> Html.Html Msg
detailView assignments assignmentSubmissions slug current_date =
    case ( assignments, assignmentSubmissions ) of
        ( RemoteData.Success assignments, RemoteData.Success submissions ) ->
            let
                maybeAssignment =
                    assignments
                        |> List.filter (\assignment -> assignment.slug == slug)
                        |> List.head

                maybeSubmission =
                    getSubmissionForSlug submissions slug
            in
            case maybeAssignment of
                Just assignment ->
                    detailViewForJustAssignment assignment maybeSubmission current_date

                Nothing ->
                    meetingNotFoundView slug

        ( _, _ ) ->
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


detailViewForJustAssignment : Assignment -> Maybe AssignmentSubmission -> Maybe Date -> Html.Html Msg
detailViewForJustAssignment assignment maybeSubmission current_date =
    Html.div []
        [ Html.h1 [] [ Html.text assignment.title, Common.Views.showDraftStatus assignment.is_draft ]
        , Html.div []
            [ Html.text "Due: "
            , Html.time [] [ Html.text (dateTimeToString assignment.closed_at) ]
            ]
        , Markdown.toHtml [] assignment.body
        , Html.hr [] []
        , case maybeSubmission of
            Just submission ->
                Html.div []
                    [ showPreviousAssignment assignment submission
                    , Html.hr [] []
                    , Html.h3 [] [ Html.text "Update submission" ]
                    , submissionInstructions assignment submission
                    ]

            Nothing ->
                beginSubmission assignment
        ]


showPreviousAssignment : Assignment -> AssignmentSubmission -> Html.Html Msg
showPreviousAssignment assignment submission =
    let
        show =
            showPreviousSubmissionField submission.fields
    in
    Html.div []
        ([ Html.h3
            []
            [ Html.text "Your existing submission" ]
         ]
            ++ List.map
                show
                assignment.fields
        )


beginSubmission : Assignment -> Html.Html Msg
beginSubmission assignment =
    Html.button [ Attrs.class "btn btn-primary" ] [ Html.text "Begin assignment" ]


submissionInstructions : Assignment -> AssignmentSubmission -> Html.Html Msg
submissionInstructions assignment submission =
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


getSubmissionValueForFieldID : List AssignmentFieldSubmission -> Int -> String
getSubmissionValueForFieldID fieldSubmissions fieldID =
    let
        maybeSubmission =
            fieldSubmissions
                |> List.filter (\f -> f.assignment_field_id == fieldID)
                |> List.head
    in
    case maybeSubmission of
        Just submission ->
            submission.body

        Nothing ->
            "Nothing"


showPreviousSubmissionField : List AssignmentFieldSubmission -> AssignmentField -> Html.Html Msg
showPreviousSubmissionField fieldSubmissions field =
    let
        fieldType =
            if field.is_url then
                "url"
            else
                "text"
    in
    Html.div []
        [ Html.label [] [ Html.text field.label ]
        , case field.is_multiline of
            True ->
                Html.textarea
                    [ Attrs.class "textarea"
                    , Attrs.placeholder field.placeholder
                    , Attrs.name (toString field.id)
                    , Attrs.value (getSubmissionValueForFieldID fieldSubmissions field.id)
                    , Attrs.disabled True
                    ]
                    []

            False ->
                Html.input
                    [ Attrs.type_ fieldType
                    , Attrs.class "input field"
                    , Attrs.placeholder field.placeholder
                    , Attrs.title field.help
                    , Attrs.name (toString field.id)
                    , Attrs.value (getSubmissionValueForFieldID fieldSubmissions field.id)
                    , Attrs.disabled True
                    ]
                    []
        ]
