module Assignments.Views exposing (detailView, listView, gradeView)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentField
        , AssignmentFieldSubmission
        , AssignmentGradeException
        , AssignmentGrade
        , AssignmentSlug
        , AssignmentSubmission
        , NotSubmissibleReason(..)
        , PendingBeginAssignments
        , SubmissibleState(..)
        , isSubmissible
        , submissionBelongsToUser
        )
import Auth.Model exposing (CurrentUser)
import Auth.Views
import Common.Views exposing (longDateToString)
import Dict exposing (Dict)
import Html exposing (Html, a, div, h1, text)
import Html.Attributes as Attrs
import Html.Events as Events
import Http exposing (Error)
import Json.Decode as Decode
import Markdown
import Models exposing (TimeZone)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Time exposing (Posix)


listView : TimeZone -> WebData (List Assignment) -> Html Msg
listView timeZone wdAssignments =
    case wdAssignments of
        RemoteData.NotAsked ->
            loginToViewAssignments

        RemoteData.Loading ->
            Html.text "Loading..."

        RemoteData.Success assignments ->
            listAssignments timeZone assignments

        RemoteData.Failure error ->
            loginToViewAssignments

-- Function takes two WebData values and returns a WebData value
-- that is the result of combining the two values. If either is
-- a failure, the result is a failure. If either is Loading, the
-- result is Loading. If either is NotAsked, the result is NotAsked.
-- If both are Success, the result is Success.
combineWebData : WebData a -> WebData b -> WebData (a, b)
combineWebData wd1 wd2 =
    case (wd1, wd2) of
        (RemoteData.Success a, RemoteData.Success b) ->
            RemoteData.Success (a, b)

        (RemoteData.Failure error, _) ->
            RemoteData.Failure error

        (_, RemoteData.Failure error) ->
            RemoteData.Failure error

        (RemoteData.Loading, _) ->
            RemoteData.Loading

        (_, RemoteData.Loading) ->
            RemoteData.Loading

        (RemoteData.NotAsked, _) ->
            RemoteData.NotAsked

        (_, RemoteData.NotAsked) ->
            RemoteData.NotAsked

gradeView : WebData (List AssignmentGrade) -> WebData (List AssignmentSubmission) -> AssignmentSlug ->WebData (CurrentUser) -> Html Msg
gradeView wdAssignmentGrades wdAssignmentSubmissions assignmentSlug wdCurrentUser =
    let 
        wd = combineWebData wdAssignmentGrades wdAssignmentSubmissions
    in 
    case wdCurrentUser of 
        RemoteData.Success currentUser ->
            case wd of
                RemoteData.NotAsked ->
                    loginToViewAssignments

                RemoteData.Loading ->
                    Html.text "Loading..."

                RemoteData.Success (grades, submissions) ->
                    gradeViewForAssignment grades submissions assignmentSlug currentUser

                RemoteData.Failure _ ->
                    loginToViewAssignments

        _ ->
            loginToViewAssignments

gradeViewForAssignment : List AssignmentGrade -> List AssignmentSubmission -> AssignmentSlug -> CurrentUser -> Html Msg
gradeViewForAssignment assignmentGrades assignmentSubmissions assignmentSlug currentUser =
    let
        maybeAssignmentSubmission =
            getSubmissionForSlug assignmentSubmissions assignmentSlug (RemoteData.Success currentUser)
        maybeAssignmentGrade =
            assignmentGrades
                |> List.filter (\assignmentGrade -> assignmentGrade.assignment_slug == assignmentSlug)
                -- Get only hte assignments that have submissions
                |> List.filter (\assignmentGrade -> 
                    case maybeAssignmentSubmission of 
                        Just assignmentSubmission ->
                            assignmentSubmission.id == assignmentGrade.assignment_submission_id

                        Nothing ->
                            False
                    )
                |> List.head
    in
    case maybeAssignmentGrade of
        Just assignmentGrade ->
            gradeViewForAssignmentGrade assignmentGrade

        Nothing ->
            Html.text "No such assignment"

gradeViewForAssignmentGrade : AssignmentGrade -> Html Msg
gradeViewForAssignmentGrade assignmentGrade =
    case assignmentGrade.description of 
        Just description ->
            Html.div []
                [
                    Html.pre [] [Html.text description]
                ]

        Nothing ->
            Html.text "No grade"

loginToViewAssignments : Html Msg
loginToViewAssignments =
    Html.div []
        [ div []
            [ Html.text "Either there was an error or you are not permited to view assignments." ]
        , div
            []
            [ Auth.Views.loginLink ]
        ]


listAssignments : TimeZone -> List Assignment -> Html Msg
listAssignments timeZone assignments =
    let
        assignmentDetails =
            List.map (\a -> { date = a.closed_at, title = a.title, href = "#assignments/" ++ a.slug, isDraft = a.is_draft }) assignments
    in
    Html.div [] (List.map (Common.Views.dateTitleHrefRow timeZone) assignmentDetails)


getSubmissionForSlug : List AssignmentSubmission -> AssignmentSlug -> WebData CurrentUser -> Maybe AssignmentSubmission
getSubmissionForSlug submissions slug wdCurrentUser =
    case wdCurrentUser of
        RemoteData.Success u ->
            submissions
                |> List.filter (\s -> s.assignment_slug == slug)
                |> List.filter (submissionBelongsToUser u)
                |> List.head

        _ ->
            Nothing


type alias DetailViewData =
    { user : CurrentUser
    , date : Posix
    , assignments : List Assignment
    , submissions : List AssignmentSubmission
    }


maybeAndMap : Maybe a -> Maybe (a -> b) -> Maybe b
maybeAndMap =
    Maybe.map2 (|>)


mergeDetailViewData : WebData CurrentUser -> Maybe Posix -> WebData (List Assignment) -> WebData (List AssignmentSubmission) -> Maybe DetailViewData
mergeDetailViewData wdCurrentUser maybeDate wdAssignments wdAssignmentSubmissions =
    let
        buildData =
            \user assignments submissions date -> { user = user, date = date, assignments = assignments, submissions = submissions }

        d =
            RemoteData.fromMaybe Result.Err maybeDate
    in
    Just buildData
        |> maybeAndMap (RemoteData.toMaybe wdCurrentUser)
        |> maybeAndMap (RemoteData.toMaybe wdAssignments)
        |> maybeAndMap (RemoteData.toMaybe wdAssignmentSubmissions)
        |> maybeAndMap maybeDate


exceptionMatches : AssignmentSlug -> Int -> Maybe String -> AssignmentGradeException -> Bool
exceptionMatches slug user_id maybeNickname exception =
    if exception.assignment_slug == slug then
        case exception.user_id of
            Just exception_user_id ->
                exception_user_id == user_id

            Nothing ->
                case ( exception.team_nickname, maybeNickname ) of
                    ( Just exception_team_nickname, Just team_nickname ) ->
                        exception_team_nickname == team_nickname

                    ( _, _ ) ->
                        False

    else
        False


detailView : WebData CurrentUser -> Maybe Posix -> TimeZone -> WebData (List Assignment) -> WebData (List AssignmentSubmission) -> WebData (List AssignmentGradeException) -> PendingBeginAssignments -> AssignmentSlug -> Maybe Posix -> Html.Html Msg
detailView wdCurrentUser maybeDate timeZone wdAssignments assignmentSubmissions wdExceptions pendingBeginAssignments slug current_date =
    case mergeDetailViewData wdCurrentUser maybeDate wdAssignments assignmentSubmissions of
        Just data ->
            let
                maybeAssignment =
                    data.assignments
                        |> List.filter (\assignment -> assignment.slug == slug)
                        |> List.head

                maybeSubmission =
                    getSubmissionForSlug data.submissions slug (RemoteData.Success data.user)

                maybePendingBegin =
                    Dict.get slug pendingBeginAssignments
            in
            case maybeAssignment of
                Just assignment ->
                    detailViewForJustAssignment data.user data.date timeZone assignment maybeSubmission wdExceptions maybePendingBegin

                Nothing ->
                    meetingNotFoundView slug

        Nothing ->
            loginToViewAssignments


meetingNotFoundView : String -> Html msg
meetingNotFoundView slug =
    Html.div []
        [ Html.text ("No such class meeting" ++ slug)
        ]



-- DateFormat.format "%l:%M%p %A, %B %e, %Y" date
-- TODO: hide the form when the client knows the closed_at date is passed.


showDueDate : Posix -> TimeZone -> Maybe AssignmentGradeException -> AssignmentSlug -> CurrentUser -> String
showDueDate dueDate timeZone maybeException slug user =
    let
        dueString =
            longDateToString dueDate timeZone ++ "."
    in
    case maybeException of
        Just exception ->
            longDateToString exception.closed_at timeZone ++ " due to your grading exception/extention. The assignment was originally due " ++ dueString

        Nothing ->
            dueString


detailViewForJustAssignment : CurrentUser -> Posix -> TimeZone -> Assignment -> Maybe AssignmentSubmission -> WebData (List AssignmentGradeException) -> Maybe (WebData AssignmentSubmission) -> Html.Html Msg
detailViewForJustAssignment user currentDate timeZone assignment maybeSubmission wdExceptions maybeBeginAssignment =
    let
        maybeException =
            wdExceptions
                |> RemoteData.toMaybe
                |> Maybe.map (List.filter (exceptionMatches assignment.slug user.id user.team_nickname))
                |> Maybe.andThen List.head
    in
    Html.div []
        [ Html.h1 [] [ Html.text assignment.title, Common.Views.showDraftStatus assignment.is_draft ]
        , Html.div []
            [ Html.text "Due: "
            , Html.time [] [ Html.text (showDueDate assignment.closed_at timeZone maybeException assignment.slug user) ]
            ]
        , Markdown.toHtml [] assignment.body
        , Html.hr [] []
        , case maybeSubmission of
            Just submission ->
                Html.div []
                    [ showPreviousAssignment assignment submission
                    , Html.hr [] []
                    , Html.h3 [] [ Html.text "Update submission" ]
                    , submissionInstructions currentDate assignment maybeException submission
                    ]

            Nothing ->
                beginSubmission currentDate assignment maybeException maybeBeginAssignment
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


beginSubmission : Posix -> Assignment -> Maybe AssignmentGradeException -> Maybe (WebData AssignmentSubmission) -> Html.Html Msg
beginSubmission currentDate assignment maybeException maybeBeginAssignment =
    case isSubmissible currentDate maybeException assignment of
        Submissible assignment2 ->
            showBeginAssignmentButton assignment2 maybeException maybeBeginAssignment

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


showBeginAssignmentButton : Assignment -> Maybe AssignmentGradeException -> Maybe (WebData AssignmentSubmission) -> Html.Html Msg
showBeginAssignmentButton assignment maybeException maybeBeginAssignment =
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
            Html.div [ Attrs.class "red" ] [ Html.text "HTTP error!" ]

        _ ->
            Html.text "other error"


spinner : Html.Html Msg
spinner =
    Html.span [ Attrs.class "btn-icon" ]
        [ Html.i [ Attrs.class "fas fa-sync fa-spin" ] []
        ]


submissionInstructions : Posix -> Assignment -> Maybe AssignmentGradeException -> AssignmentSubmission -> Html.Html Msg
submissionInstructions currentDate assignment maybeException submission =
    case isSubmissible currentDate maybeException assignment of
        Submissible assignment2 ->
            showSubmissionForm submission assignment2

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


showSubmissionForm : AssignmentSubmission -> Assignment -> Html.Html Msg
showSubmissionForm submission assignment =
    Html.form
        [ Events.custom
            "submit"
            (Decode.succeed
                { preventDefault = True
                , stopPropagation = False
                , message = Msgs.OnSubmitAssignmentFieldSubmissions submission
                }
            )
        ]
        (List.map (showFormField submission) assignment.fields ++ [ Html.button [ Attrs.class "btn btn-primary" ] [ Html.text "Submit" ] ])


showFormField : AssignmentSubmission -> AssignmentField -> Html.Html Msg
showFormField submission assignmentField =
    let
        fieldType =
            if assignmentField.is_url then
                "url"

            else
                "text"
        commonAttributes = [
            Attrs.placeholder assignmentField.placeholder
            , Attrs.title assignmentField.help
            , Attrs.name assignmentField.slug
            , Attrs.pattern assignmentField.pattern
            , Events.onInput
            (Msgs.OnUpdateAssignmentFieldSubmissionInput
                submission.id
                assignmentField.slug
            )]
    in
    Html.div []
        [ Html.label [] [ Html.text assignmentField.label ]
        , if assignmentField.is_multiline then
                Html.textarea
                    ( Attrs.class "textarea" :: commonAttributes)
                    []
            else
                Html.input
                    ([ Attrs.type_ fieldType , Attrs.class "input field" ] ++ commonAttributes)
                    []
        ]


getSubmissionValueForFieldSlug : List AssignmentFieldSubmission -> String -> String
getSubmissionValueForFieldSlug fieldSubmissions fieldSlug =
    let
        maybeSubmission =
            fieldSubmissions
                |> List.filter (\f -> f.assignment_field_slug == fieldSlug)
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
                    , Attrs.name field.slug
                    , Attrs.value (getSubmissionValueForFieldSlug fieldSubmissions field.slug)
                    , Attrs.disabled True
                    ]
                    []

            False ->
                Html.input
                    [ Attrs.type_ fieldType
                    , Attrs.class "input field"
                    , Attrs.placeholder field.placeholder
                    , Attrs.title field.help
                    , Attrs.name field.slug
                    , Attrs.value (getSubmissionValueForFieldSlug fieldSubmissions field.slug)
                    , Attrs.disabled True
                    ]
                    []
        ]
