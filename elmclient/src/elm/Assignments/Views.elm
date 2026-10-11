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
        , AssignmentSubmissionAction(..)
        , PendingAssignmentFieldSubmissionRequests
        , PendingBeginAssignments
        , assignmentSubmissionAction
        , notSubmissibleMessage
        , submissionBelongsToUser
        )
import Auth.Model exposing (CurrentUser)
import Auth.Views
import Common.Views exposing (longDateToString)
import DateFormat
import Dict
import Html exposing (Html, a, div)
import Html.Attributes as Attrs
import Html.Events as Events
import Http
import Json.Decode as Decode
import Markdown
import Models exposing (TimeZone)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Time exposing (Posix, Zone)


listView : TimeZone -> WebData (List Assignment) -> Html Msg
listView timeZone wdAssignments =
    case wdAssignments of
        RemoteData.NotAsked ->
            loginToViewAssignments

        RemoteData.Loading ->
            Html.text "Loading..."

        RemoteData.Success assignments ->
            listAssignments timeZone assignments

        RemoteData.Failure _ ->
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
    Html.div [] (List.map (assignmentRow timeZone) assignments)


assignmentRow : TimeZone -> Assignment -> Html Msg
assignmentRow timeZone assignment =
    Html.div [ Attrs.class "clearfix mb2" ]
        [ Html.time [ Attrs.class "left p1 mr1 classdate" ]
            [ Html.div [] [ Html.text (shortDayOfWeek assignment.closed_at timeZone.zone) ]
            , Html.div [] [ Html.text (shortDateMonth assignment.closed_at timeZone.zone) ]
            ]
        , Html.div [ Attrs.class "overflow-hidden p1" ]
            [ Html.a
                [ Attrs.href ("#assignments/" ++ assignment.slug) ]
                [ Html.text assignment.title ]
            , Common.Views.showDraftStatus assignment.is_draft
            , Html.div [] [ Html.text (pointsPossibleText assignment.points_possible) ]
            ]
        ]


shortDayOfWeek : Posix -> Zone -> String
shortDayOfWeek time zone =
    DateFormat.format [ DateFormat.dayOfWeekNameAbbreviated ] zone time


shortDateMonth : Posix -> Zone -> String
shortDateMonth time zone =
    DateFormat.format [ DateFormat.dayOfMonthFixed, DateFormat.monthNameAbbreviated ] zone time


{-| Just "15 points". It read "Points possible: 15 points", which says points
twice and buries the number in the middle of the phrase -- in a list where
every row carries one, the label is the part nobody needs.
-}
pointsPossibleText : Int -> String
pointsPossibleText points =
    String.fromInt points
        ++ (if points == 1 then
                " point"

            else
                " points"
           )


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


detailView : WebData CurrentUser -> Maybe Posix -> TimeZone -> WebData (List Assignment) -> WebData (List AssignmentSubmission) -> WebData (List AssignmentGradeException) -> PendingBeginAssignments -> PendingAssignmentFieldSubmissionRequests -> AssignmentSlug -> Maybe Posix -> Html.Html Msg
detailView wdCurrentUser maybeDate timeZone wdAssignments assignmentSubmissions wdExceptions pendingBeginAssignments pendingSaves slug _ =
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

                maybePendingSave =
                    Dict.get slug pendingSaves
            in
            case maybeAssignment of
                Just assignment ->
                    detailViewForJustAssignment data.user data.date timeZone assignment maybeSubmission wdExceptions maybePendingBegin maybePendingSave

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
showDueDate dueDate timeZone maybeException _ _ =
    let
        dueString =
            longDateToString dueDate timeZone ++ "."
    in
    case maybeException of
        Just exception ->
            longDateToString exception.closed_at timeZone ++ " due to your grading exception/extention. The assignment was originally due " ++ dueString

        Nothing ->
            dueString


detailViewForJustAssignment : CurrentUser -> Posix -> TimeZone -> Assignment -> Maybe AssignmentSubmission -> WebData (List AssignmentGradeException) -> Maybe (WebData AssignmentSubmission) -> Maybe (WebData ()) -> Html.Html Msg
detailViewForJustAssignment user currentDate timeZone assignment maybeSubmission wdExceptions maybeBeginAssignment maybePendingSave =
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
        , Html.div [] [ Html.text (pointsPossibleText assignment.points_possible) ]
        , Markdown.toHtml [] assignment.body
        , Html.hr [] []
        , case maybeSubmission of
            Just submission ->
                Html.div []
                    [ showPreviousAssignment assignment submission
                    , Html.hr [] []
                    , Html.h3 [] [ Html.text "Update submission" ]
                    , renderAssignmentSubmissionAction maybeBeginAssignment maybePendingSave
                        (assignmentSubmissionAction currentDate maybeException assignment user (Just submission))
                    ]

            Nothing ->
                renderAssignmentSubmissionAction maybeBeginAssignment maybePendingSave
                    (assignmentSubmissionAction currentDate maybeException assignment user Nothing)
        ]


showPreviousAssignment : Assignment -> AssignmentSubmission -> Html.Html Msg
showPreviousAssignment assignment submission =
    let
        show =
            showPreviousSubmissionField submission.fields
    in
    Html.div []
        (Html.h3 [] [ Html.text "Your existing submission" ]
            :: List.map show assignment.fields
        )


renderAssignmentSubmissionAction : Maybe (WebData AssignmentSubmission) -> Maybe (WebData ()) -> AssignmentSubmissionAction -> Html.Html Msg
renderAssignmentSubmissionAction maybeBeginAssignment maybePendingSave action =
    case action of
        CanBeginAssignment assignment2 ->
            showBeginAssignmentButton assignment2 maybeBeginAssignment

        CanUpdateAssignment assignment2 submission ->
            showSubmissionForm submission assignment2 maybePendingSave

        CannotSubmitAssignment reason ->
            Common.Views.divWithText (notSubmissibleMessage reason)


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

        Just (RemoteData.Failure _) ->
            Html.div [ Attrs.class "red" ] [ Html.text "HTTP error!" ]

        _ ->
            Html.text "other error"


showSubmissionForm : AssignmentSubmission -> Assignment -> Maybe (WebData ()) -> Html.Html Msg
showSubmissionForm submission assignment maybePendingSave =
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
        (List.map (showFormField submission) assignment.fields ++ [ submitButton maybePendingSave, saveResult maybePendingSave ])


submitButton : Maybe (WebData ()) -> Html.Html Msg
submitButton maybePendingSave =
    case maybePendingSave of
        Just RemoteData.Loading ->
            Html.button [ Attrs.class "btn btn-primary black bg-silver", Attrs.disabled True ] [ Html.text "Saving..." ]

        _ ->
            Html.button [ Attrs.class "btn btn-primary" ] [ Html.text "Submit" ]


{-| The inputs keep what was typed whether or not a save succeeds, so say which
it was. A failed save used to show nothing, which looked like success.
-}
saveResult : Maybe (WebData ()) -> Html.Html Msg
saveResult maybePendingSave =
    case maybePendingSave of
        Just (RemoteData.Success ()) ->
            Html.div [ Attrs.class "green" ] [ Html.text "Saved." ]

        Just (RemoteData.Failure error) ->
            Html.div [ Attrs.class "red" ] (saveErrorMessage error)

        _ ->
            Html.text ""


saveErrorMessage : Http.Error -> List (Html.Html Msg)
saveErrorMessage error =
    case error of
        Http.BadStatus 401 ->
            -- A new tab keeps what the student typed in this one.
            [ Html.text "Not saved: your login has expired. "
            , Html.a [ Attrs.href "/auth/login", Attrs.target "_blank" ] [ Html.text "Log in again" ]
            , Html.text " in a new tab, then come back and click Submit."
            ]

        Http.BadStatus code ->
            [ Html.text
                ("Not saved: the server rejected this submission (HTTP "
                    ++ String.fromInt code
                    ++ "). Check that each value matches the required format and that the assignment is still open."
                )
            ]

        Http.NetworkError ->
            [ Html.text "Not saved: could not reach the server. Check your connection and click Submit again." ]

        Http.Timeout ->
            [ Html.text "Not saved: the server took too long to respond. Click Submit again." ]

        Http.BadBody _ ->
            [ Html.text "The server's reply could not be read. Reload the page to check whether your submission was saved." ]

        Http.BadUrl _ ->
            [ Html.text "Not saved: the request could not be sent. Reload the page and try again." ]


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
        , if field.is_multiline then
                Html.textarea
                    [ Attrs.class "textarea"
                    , Attrs.placeholder field.placeholder
                    , Attrs.name field.slug
                    , Attrs.value (getSubmissionValueForFieldSlug fieldSubmissions field.slug)
                    , Attrs.disabled True
                    ]
                    []
            else
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
