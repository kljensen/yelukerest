module Assignments.Views exposing (detailView, listView)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentField
        , AssignmentFieldSubmission
        , AssignmentSlug
        , AssignmentSubmission
        , NotSubmissibleReason(..)
        , PendingBeginAssignments
        , SubmissibleState(..)
        , isSubmissible
        )
import Auth.Views
import Common.Views
import Date exposing (Date)
import Date.Format as DateFormat
import Dict exposing (Dict)
import Html exposing (Html, a, div, h1, text)
import Html.Attributes as Attrs
import Html.Events as Events
import Json.Decode as Decode
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


detailView : Maybe Date.Date -> WebData (List Assignment) -> WebData (List AssignmentSubmission) -> PendingBeginAssignments -> AssignmentSlug -> Maybe Date -> Html.Html Msg
detailView maybeDate assignments assignmentSubmissions pendingBeginAssignments slug current_date =
    case ( assignments, assignmentSubmissions ) of
        ( RemoteData.Success assignments, RemoteData.Success submissions ) ->
            let
                maybeAssignment =
                    assignments
                        |> List.filter (\assignment -> assignment.slug == slug)
                        |> List.head

                maybeSubmission =
                    getSubmissionForSlug submissions slug

                maybePendingBegin =
                    Dict.get slug pendingBeginAssignments
            in
            case ( maybeDate, maybeAssignment ) of
                ( Just currentDate, Just assignment ) ->
                    detailViewForJustAssignment currentDate assignment maybeSubmission maybePendingBegin current_date

                ( Nothing, _ ) ->
                    Html.div [] [ Html.text "Loading..." ]

                ( _, Nothing ) ->
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
    DateFormat.format "%l:%M%p %A, %B %e, %Y" date



-- TODO: hide the form when the client knows the closed_at date is passed.


detailViewForJustAssignment : Date.Date -> Assignment -> Maybe AssignmentSubmission -> Maybe (WebData AssignmentSubmission) -> Maybe Date -> Html.Html Msg
detailViewForJustAssignment currentDate assignment maybeSubmission maybeBeginAssignment current_date =
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
                    , submissionInstructions currentDate assignment submission
                    ]

            Nothing ->
                beginSubmission currentDate assignment maybeBeginAssignment
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


beginSubmission : Date.Date -> Assignment -> Maybe (WebData AssignmentSubmission) -> Html.Html Msg
beginSubmission currentDate assignment maybeBeginAssignment =
    case isSubmissible currentDate assignment of
        Submissible assignment ->
            showBeginAssignmentButton assignment maybeBeginAssignment

        NotSubmissible reason ->
            let
                message =
                    case reason of
                        IsAfterClosed ->
                            "This assignment is now closed for submissions."

                        IsDraft ->
                            "This assignment is still in draft mode and cannot yet be submitted."
            in
            Common.Views.divWithText message


showBeginAssignmentButton : Assignment -> Maybe (WebData AssignmentSubmission) -> Html.Html Msg
showBeginAssignmentButton assignment maybeBeginAssignment =
    case maybeBeginAssignment of
        Nothing ->
            Html.button
                [ Attrs.class "btn btn-primary"
                , Events.onClick (Msgs.OnBeginAssignment assignment.slug)
                ]
                [ Html.text "Begin assignment"
                ]

        Just RemoteData.Loading ->
            Html.button
                [ Attrs.class "btn btn-primary black bg-silver"
                , Attrs.disabled True
                ]
                [ Html.text "Begin assignment"
                ]

        Just (RemoteData.Failure error) ->
            Html.div [ Attrs.class "red" ] [ Html.text (toString error) ]

        _ ->
            Html.text "other error"


spinner : Html.Html Msg
spinner =
    Html.span [ Attrs.class "btn-icon" ]
        [ Html.i [ Attrs.class "fas fa-sync fa-spin" ] []
        ]


submissionInstructions : Date.Date -> Assignment -> AssignmentSubmission -> Html.Html Msg
submissionInstructions currentDate assignment submission =
    case isSubmissible currentDate assignment of
        Submissible assignment ->
            showSubmissionForm assignment

        NotSubmissible reason ->
            let
                message =
                    case reason of
                        IsAfterClosed ->
                            "This assignment is now closed for submissions."

                        IsDraft ->
                            "This assignment is still in draft mode and cannot yet be submitted."
            in
            Common.Views.divWithText message


showSubmissionForm : Assignment -> Html.Html Msg
showSubmissionForm assignment =
    Html.form
        [ Events.onWithOptions
            "submit"
            { preventDefault = True, stopPropagation = False }
            (Decode.succeed (Msgs.OnSubmitAssignmentFieldSubmissions assignment))
        ]
        (List.map showFormField assignment.fields ++ [ Html.button [ Attrs.class "btn btn-primary" ] [ Html.text "Submit" ] ])


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
                    , Events.onInput
                        (Msgs.OnUpdateAssignmentFieldSubmissionInput
                            assignmentField.id
                        )
                    ]
                    []

            False ->
                Html.input
                    [ Attrs.type_ fieldType
                    , Attrs.class "input field"
                    , Attrs.placeholder assignmentField.placeholder
                    , Attrs.title assignmentField.help
                    , Attrs.name (toString assignmentField.id)
                    , Events.onInput
                        (Msgs.OnUpdateAssignmentFieldSubmissionInput
                            assignmentField.id
                        )
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
            "NO SUBMISSION"


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
