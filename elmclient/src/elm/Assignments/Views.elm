module Assignments.Views exposing (detailView, listView, gradeView)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentField
        , AssignmentFieldSubmission
        , AssignmentGradeException
        , AssignmentGrade
        , AssignmentRepositories
        , AssignmentSlug
        , AssignmentSubmission
        , AssignmentSubmissionAction(..)
        , PendingBeginAssignments
        , RepositoryError
        , RepositoryProgress(..)
        , RepositoryState(..)
        , RepositoryStatus
        , assignmentSubmissionAction
        , notSubmissibleMessage
        , submissionBelongsToUser
        , usesRepositoryFlow
        )
import Auth.Model exposing (CurrentUser)
import Auth.Views
import Common.Views exposing (longDateToString)
import DateFormat
import Dict
import Html exposing (Html, a, div)
import Html.Attributes as Attrs
import Html.Events as Events
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


detailView : WebData CurrentUser -> Maybe Posix -> TimeZone -> WebData (List Assignment) -> WebData (List AssignmentSubmission) -> WebData (List AssignmentGradeException) -> PendingBeginAssignments -> AssignmentRepositories -> AssignmentSlug -> Maybe Posix -> Html.Html Msg
detailView wdCurrentUser maybeDate timeZone wdAssignments assignmentSubmissions wdExceptions pendingBeginAssignments repositories slug _ =
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

                maybeRepository =
                    Dict.get slug repositories
            in
            case maybeAssignment of
                Just assignment ->
                    detailViewForJustAssignment data.user data.date timeZone assignment maybeSubmission wdExceptions maybePendingBegin maybeRepository

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


detailViewForJustAssignment : CurrentUser -> Posix -> TimeZone -> Assignment -> Maybe AssignmentSubmission -> WebData (List AssignmentGradeException) -> Maybe (WebData AssignmentSubmission) -> Maybe RepositoryProgress -> Html.Html Msg
detailViewForJustAssignment user currentDate timeZone assignment maybeSubmission wdExceptions maybeBeginAssignment maybeRepository =
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
                    , renderAssignmentSubmissionAction maybeBeginAssignment
                        (repositoryFlow user currentDate maybeRepository)
                        (assignmentSubmissionAction currentDate maybeException assignment user (Just submission))
                    ]

            Nothing ->
                renderAssignmentSubmissionAction maybeBeginAssignment
                    (repositoryFlow user currentDate maybeRepository)
                    (assignmentSubmissionAction currentDate maybeException assignment user Nothing)
        ]


{-| What the repository flow needs to draw itself, when the assignment and
person get it (see `Assignments.Model.usesRepositoryFlow`).
-}
type alias RepositoryFlow =
    { user : CurrentUser
    , now : Posix
    , progress : Maybe RepositoryProgress
    }


repositoryFlow : CurrentUser -> Posix -> Maybe RepositoryProgress -> RepositoryFlow
repositoryFlow user now progress =
    { user = user, now = now, progress = progress }


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


{-| A student's assignment with a repository template gets the create/poll
flow in place of "Begin assignment": creating the repository begins the
submission on the server. The flow stays above the form once a submission
exists, so a student whose repository was never made (or is still being
made) can see that from the same page they submit on. Everything else,
including staff looking at such an assignment, is as before.
-}
renderAssignmentSubmissionAction : Maybe (WebData AssignmentSubmission) -> RepositoryFlow -> AssignmentSubmissionAction -> Html.Html Msg
renderAssignmentSubmissionAction maybeBeginAssignment flow action =
    case action of
        CanBeginAssignment assignment2 ->
            if usesRepositoryFlow flow.user assignment2 then
                showRepositoryProgress assignment2 flow

            else
                showBeginAssignmentButton assignment2 maybeBeginAssignment

        CanUpdateAssignment assignment2 submission ->
            if usesRepositoryFlow flow.user assignment2 then
                Html.div []
                    [ showRepositoryProgress assignment2 flow
                    , showSubmissionForm submission assignment2
                    ]

            else
                showSubmissionForm submission assignment2

        CannotSubmitAssignment reason ->
            Common.Views.divWithText (notSubmissibleMessage reason)


showRepositoryProgress : Assignment -> RepositoryFlow -> Html.Html Msg
showRepositoryProgress assignment flow =
    let
        createLabel =
            if assignment.is_team then
                "Create our team repository"

            else
                "Create my repository"
    in
    Html.div [ Attrs.class "mb2" ]
        (case flow.progress of
            Nothing ->
                [ Html.text "Checking your repository…" ]

            Just Checking ->
                [ Html.text "Checking your repository…" ]

            Just NotStarted ->
                [ Html.button
                    [ Attrs.class "btn btn-primary"
                    , Events.onClick (Msgs.OnCreateRepository assignment.slug)
                    ]
                    [ Html.text createLabel ]
                ]

            Just Creating ->
                [ Html.button
                    [ Attrs.class "btn btn-primary black bg-silver"
                    , Attrs.disabled True
                    ]
                    [ Html.text "Creating your private repository…" ]
                ]

            Just (Polling polling) ->
                [ repositoryLink polling.last
                , Html.div [] [ Html.text "Starter files are being copied — usually under a minute." ]
                ]

            Just (PollTimedOut status) ->
                [ repositoryLink status
                , Html.div []
                    [ Html.text "Still copying. "
                    , actionButton (Msgs.OnLoadRepository assignment.slug) "Check again" Nothing
                    ]
                ]

            Just (Done status) ->
                [ case status.repoUrl of
                    Just url ->
                        Html.a [ Attrs.class "btn btn-primary", Attrs.href url ] [ Html.text "Open your repository" ]

                    Nothing ->
                        Html.text "Your repository is ready."
                ]

            Just (Blocked blocked) ->
                showRepositoryBlocked assignment.slug (secondsOfHold flow.now blocked.notBefore) blocked.status

            Just (Failed failed) ->
                showRepositoryFailed assignment.slug (secondsOfHold flow.now failed.notBefore) failed.error
        )


repositoryLink : RepositoryStatus -> Html.Html Msg
repositoryLink status =
    case status.repoUrl of
        Just url ->
            Html.div [] [ Html.a [ Attrs.href url ] [ Html.text url ] ]

        Nothing ->
            Html.text ""


{-| How much of a rate limit's hold is left, if any. The clock is the
model's five-second `Tick`, so the count shown moves in steps of five.
-}
secondsOfHold : Posix -> Maybe Posix -> Maybe Int
secondsOfHold now maybeNotBefore =
    maybeNotBefore
        |> Maybe.map (\notBefore -> (Time.posixToMillis notBefore - Time.posixToMillis now + 999) // 1000)
        |> Maybe.andThen
            (\seconds ->
                if seconds > 0 then
                    Just seconds

                else
                    Nothing
            )


{-| A button that a rate limit's hold turns off, saying for how long.
-}
actionButton : Msg -> String -> Maybe Int -> Html.Html Msg
actionButton msg label holdSeconds =
    case holdSeconds of
        Just seconds ->
            Html.span []
                [ Html.button
                    [ Attrs.class "btn btn-primary black bg-silver"
                    , Attrs.disabled True
                    ]
                    [ Html.text label ]
                , Html.text (" You can try again in " ++ String.fromInt seconds ++ " s.")
                ]

        Nothing ->
            Html.button
                [ Attrs.class "btn btn-primary"
                , Events.onClick msg
                ]
                [ Html.text label ]


{-| A prerequisite the student has to meet first. Both end with "Try
again", which asks the server to create once more: that is what re-checks
the prerequisite.
-}
showRepositoryBlocked : AssignmentSlug -> Maybe Int -> RepositoryStatus -> List (Html.Html Msg)
showRepositoryBlocked slug holdSeconds status =
    let
        tryAgain =
            actionButton (Msgs.OnCreateRepository slug) "Try again" holdSeconds
    in
    case ( status.state, status.joinUrl ) of
        ( NeedsOrgJoin, Just joinUrl ) ->
            [ Html.div [] [ Html.text "You need to join the course GitHub organization before a repository can be created for you." ]
            , Html.a [ Attrs.class "btn btn-primary mr1", Attrs.href joinUrl ] [ Html.text "Join the course GitHub organization" ]
            , tryAgain
            ]

        ( NeedsOrgJoin, Nothing ) ->
            [ Html.div [] [ Html.text "You need to accept the GitHub organization invitation first (check your email), then try again." ]
            , tryAgain
            ]

        _ ->
            [ Html.div [] [ Html.text "We don't have a working GitHub username for you; tell the teaching staff." ]
            , tryAgain
            ]


{-| A request that failed. `provisioning_interrupted` is the one failure
with a next step of its own: an earlier create was cut off, and posting
again picks it up. Anything else retryable gets "Try again", which asks the
server where things stand rather than creating blindly, since after a
failed create the server may well hold a repository already. The rest are
explained where the client can, and otherwise name their code so the
teaching staff can find the attempt.
-}
showRepositoryFailed : AssignmentSlug -> Maybe Int -> RepositoryError -> List (Html.Html Msg)
showRepositoryFailed slug holdSeconds error =
    if error.code == "provisioning_interrupted" then
        [ Html.div [] [ Html.text "An earlier attempt to create your repository was interrupted before it finished." ]
        , actionButton (Msgs.OnCreateRepository slug) "Resume" holdSeconds
        ]

    else if error.retryable then
        [ Html.div [ Attrs.class "red" ] [ Html.text (repositoryErrorMessage error) ]
        , actionButton (Msgs.OnLoadRepository slug) "Try again" holdSeconds
        ]

    else
        [ Html.div [ Attrs.class "red" ] [ Html.text (repositoryErrorMessage error) ] ]


repositoryErrorMessage : RepositoryError -> String
repositoryErrorMessage error =
    if error.httpStatus == 429 then
        -- The button beneath says how long the wait is.
        "Too many requests. Please wait before trying again."

    else
        case error.code of
            "assignment_closed" ->
                "This assignment is closed, so a repository can no longer be created for it."

            "not_a_student" ->
                "Only students can create assignment repositories."

            "no_team" ->
                "You need to be on a team before a team repository can be created."

            "session_expired" ->
                "Your session has expired. Reload the page and sign in again."

            "github_unavailable" ->
                "GitHub did not respond. Try again in a moment."

            "repository_not_visible" ->
                "The repository was created, but GitHub has not made it visible yet. Try again in a moment."

            "timeout" ->
                "The request took too long. Try again in a moment."

            "network_error" ->
                "We could not reach the server. Check your connection and try again."

            _ ->
                if error.retryable then
                    "Something went wrong (" ++ error.code ++ "). Try again in a moment."

                else
                    -- name_taken, repository_conflict, submission_conflict and
                    -- anything else the server refuses outright: nothing the
                    -- student can do alone, so the code goes to whoever can.
                    "We could not create your repository. Please tell the teaching staff and mention the code \"" ++ error.code ++ "\"."


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
