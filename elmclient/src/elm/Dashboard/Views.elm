module Dashboard.Views exposing (dashboard)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentGrade
        , AssignmentGradeDistribution
        , AssignmentSubmission
        , submissionBelongsToUser
        )
import Auth.Model exposing (CurrentUser)
import Auth.Views exposing (loginLink)
import Common.Comparisons exposing (sortByDate)
import Date exposing (Date)
import Date.Format as DateFormat
import Html exposing (Html)
import Html.Attributes as Attrs
import Meetings.Model exposing (Meeting)
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( Quiz
        , QuizGrade
        , QuizGradeDistribution
        , QuizSubmission
        )
import RemoteData exposing (WebData)


type alias WebDataGradeData a =
    { a
        | currentUser : WebData CurrentUser
        , meetings : WebData (List Meeting)
        , assignments : WebData (List Assignment)
        , assignmentSubmissions : WebData (List AssignmentSubmission)
        , assignmentGrades : WebData (List AssignmentGrade)
        , assignmentGradeDistributions : WebData (List AssignmentGradeDistribution)
        , quizzes : WebData (List Quiz)
        , quizSubmissions : WebData (List QuizSubmission)
        , quizGrades : WebData (List QuizGrade)
        , quizGradeDistributions : WebData (List QuizGradeDistribution)
    }


type alias GradeData =
    { currentUser : CurrentUser
    , meetings : List Meeting
    , assignments : List Assignment
    , assignmentSubmissions : List AssignmentSubmission
    , assignmentGrades : List AssignmentGrade
    , assignmentGradeDistributions : List AssignmentGradeDistribution
    , quizzes : List Quiz
    , quizSubmissions : List QuizSubmission
    , quizGrades : List QuizGrade
    , quizGradeDistributions : List QuizGradeDistribution
    }


type alias AssignmentGradeData a =
    { a
        | currentUser : CurrentUser
        , assignments : List Assignment
        , assignmentSubmissions : List AssignmentSubmission
        , assignmentGrades : List AssignmentGrade
        , assignmentGradeDistributions : List AssignmentGradeDistribution
    }


type alias QuizGradeData a =
    { a
        | currentUser : CurrentUser
        , meetings : List Meeting
        , quizzes : List Quiz
        , quizSubmissions : List QuizSubmission
        , quizGrades : List QuizGrade
        , quizGradeDistributions : List QuizGradeDistribution
    }


gradeDataFromWebData : WebDataGradeData a -> WebData GradeData
gradeDataFromWebData wgd =
    RemoteData.map newGradeData wgd.currentUser
        |> RemoteData.andMap wgd.meetings
        |> RemoteData.andMap wgd.assignments
        |> RemoteData.andMap wgd.assignmentSubmissions
        |> RemoteData.andMap wgd.assignmentGrades
        |> RemoteData.andMap wgd.assignmentGradeDistributions
        |> RemoteData.andMap wgd.quizzes
        |> RemoteData.andMap wgd.quizSubmissions
        |> RemoteData.andMap wgd.quizGrades
        |> RemoteData.andMap wgd.quizGradeDistributions


newGradeData :
    CurrentUser
    -> List Meeting
    -> List Assignment
    -> List AssignmentSubmission
    -> List AssignmentGrade
    -> List AssignmentGradeDistribution
    -> List Quiz
    -> List QuizSubmission
    -> List QuizGrade
    -> List QuizGradeDistribution
    -> GradeData
newGradeData currentUser meetings assignments assignmentSubmissions assignmentGrades assignmentGradeDistributions quizzes quizSubmissions quizGrades quizGradeDistributions =
    { currentUser = currentUser
    , meetings = meetings
    , assignments = assignments
    , assignmentSubmissions = assignmentSubmissions
    , assignmentGrades = assignmentGrades
    , assignmentGradeDistributions = assignmentGradeDistributions
    , quizzes = quizzes
    , quizSubmissions = quizSubmissions
    , quizGrades = quizGrades
    , quizGradeDistributions = quizGradeDistributions
    }


dashboard : WebDataGradeData a -> Html.Html Msg
dashboard webDataGradeData =
    let
        userInfo =
            case webDataGradeData.currentUser of
                RemoteData.NotAsked ->
                    Html.text ""

                RemoteData.Loading ->
                    Html.text "Loading ..."

                RemoteData.Success currentUser ->
                    showDashboard currentUser

                RemoteData.Failure err ->
                    loginLink

        gradeTable =
            maybeShowGradeTable webDataGradeData
    in
    Html.div []
        [ userInfo
        , gradeTable
        ]


showDashboard : CurrentUser -> Html.Html Msg
showDashboard currentUser =
    Html.div []
        [ Html.h2 [] [ Html.text "Your account info" ]
        , Html.table [ Attrs.class "dashboard" ]
            [ Html.tbody []
                [ dashboardRow "id" (toString currentUser.id)
                , dashboardRow "netid" currentUser.netid
                , dashboardRow "role" currentUser.role
                , dashboardRow "nickname" currentUser.nickname
                , dashboardRow "team_nickname" (Maybe.withDefault "none" currentUser.team_nickname)
                , dashboardRow "jwt" currentUser.jwt
                ]
            ]
        ]


dashboardRow : String -> String -> Html.Html Msg
dashboardRow label value =
    Html.tr []
        [ Html.td [] [ Html.text label ]
        , Html.td [] [ Html.text value ]
        ]


maybeShowGradeTable : WebDataGradeData a -> Html.Html Msg
maybeShowGradeTable webDataGradeData =
    let
        gradeData =
            gradeDataFromWebData webDataGradeData
    in
    case gradeData of
        RemoteData.Success gd ->
            showGradeTable gd

        RemoteData.Failure e ->
            Html.div [] [ Html.text ("Failed to load data:" ++ toString e) ]

        _ ->
            Html.div [] [ Html.text "Loading..." ]


showGradeTable : GradeData -> Html.Html Msg
showGradeTable gd =
    Html.div []
        [ quizGradeTable gd
        , assignmentGradeTable gd
        ]


quizGradeTable : QuizGradeData a -> Html.Html Msg
quizGradeTable gd =
    case gd.quizzes of
        [] ->
            Html.p [] [ Html.text "No quizzes yet" ]

        _ ->
            Html.div []
                [ Html.h2 [] [ Html.text "Your quiz grades" ]
                , Html.table
                    [ Attrs.class "dashboard" ]
                    (quizGradeTableContents gd)
                ]


quizGradeTableContents : QuizGradeData a -> List (Html.Html Msg)
quizGradeTableContents gd =
    [ quizGradeTableHeader ]
        ++ [ Html.tbody [] (quizGradeTableBodyContents gd) ]


quizGradeTableBodyContents : QuizGradeData a -> List (Html.Html Msg)
quizGradeTableBodyContents gd =
    List.map
        (meetingQuizRow gd)
        gd.meetings


quizGradeTableHeader : Html.Html Msg
quizGradeTableHeader =
    let
        th =
            \x -> Html.th [] [ Html.text x ]
    in
    Html.thead []
        [ Html.tr []
            [ th "Date"
            , th "Meeting"
            , th "Status"
            , th "Grade"
            , th "Class Average"
            , th "Class Stddev"
            ]
        ]


meetingQuizRow : QuizGradeData a -> Meeting -> Html.Html Msg
meetingQuizRow gd meeting =
    case getQuizForMeetingID gd.quizzes meeting.id of
        Just quiz ->
            showGradeForQuiz gd quiz meeting

        Nothing ->
            Html.text ""


maybeToStringWithDefault : String -> (a -> String) -> Maybe a -> String
maybeToStringWithDefault default f x =
    case x of
        Just y ->
            f y

        Nothing ->
            default


shortDate : Date -> String
shortDate d =
    -- The space in here is nonbreaking unicode \x00A0
    DateFormat.format "%d %b" d


showGradeForQuiz : QuizGradeData a -> Quiz -> Meeting -> Html.Html Msg
showGradeForQuiz gd quiz meeting =
    let
        td =
            \x -> Html.td [] [ Html.text x ]

        matchesQuizAndUser =
            \x -> x.quiz_id == quiz.id && x.user_id == gd.currentUser.id

        qs =
            gd.quizSubmissions
                |> List.filter matchesQuizAndUser
                |> List.head
                |> maybeToStringWithDefault "Not submitted" (\x -> "Submitted")

        grade =
            gd.quizGrades
                |> List.filter matchesQuizAndUser
                |> List.head
                |> maybeToStringWithDefault "Not graded" (\x -> toString x.points)

        maybeGdist =
            gd.quizGradeDistributions
                |> List.filter (\x -> x.quiz_id == quiz.id)
                |> List.head

        ( average, stddev ) =
            case maybeGdist of
                Just gdist ->
                    ( toString gdist.average, toString gdist.stddev )

                Nothing ->
                    ( "n/a", "n/a" )
    in
    Html.tr []
        [ td (shortDate meeting.begins_at)
        , td meeting.title
        , td qs
        , td grade
        , td average
        , td stddev
        ]


getQuizForMeetingID : List Quiz -> Int -> Maybe Quiz
getQuizForMeetingID quizzes meetingID =
    quizzes
        |> List.filter (\quiz -> quiz.meeting_id == meetingID)
        |> List.head


sortQuizzesByMeetingDate : List Meeting -> List Quiz -> List Quiz
sortQuizzesByMeetingDate meetings quizzes =
    let
        sortedMeetings =
            sortByDate .begins_at meetings
    in
    quizzes


assignmentGradeTable : AssignmentGradeData a -> Html.Html Msg
assignmentGradeTable gd =
    case gd.assignments of
        [] ->
            Html.p [] [ Html.text "No assignments yet" ]

        _ ->
            Html.div []
                [ Html.h2 [] [ Html.text "Your assignment grades" ]
                , Html.table
                    [ Attrs.class "dashboard" ]
                    (assignmentGradeTableContents gd)
                ]


assignmentGradeTableContents : AssignmentGradeData a -> List (Html.Html Msg)
assignmentGradeTableContents gd =
    [ assignmentGradeTableHeader ]
        ++ [ Html.tbody [] (assignmentGradeTableBodyContents gd) ]


assignmentGradeTableBodyContents : AssignmentGradeData a -> List (Html.Html Msg)
assignmentGradeTableBodyContents gd =
    List.map
        (showGradeForAssignment gd)
        gd.assignments


assignmentGradeTableHeader : Html.Html Msg
assignmentGradeTableHeader =
    let
        th =
            \x -> Html.th [] [ Html.text x ]
    in
    Html.thead []
        [ Html.tr []
            [ th "Date"
            , th "Assignment"
            , th "Status"
            , th "Grade"
            , th "Class Average"
            , th "Class Stddev"
            ]
        ]


showGradeForAssignment : AssignmentGradeData a -> Assignment -> Html.Html Msg
showGradeForAssignment gd assignment =
    let
        td =
            \x -> Html.td [] [ Html.text x ]

        maybeSub =
            gd.assignmentSubmissions
                |> List.filter (submissionBelongsToUser gd.currentUser)
                |> List.head

        subInfo =
            maybeToStringWithDefault "Not submitted" (\x -> "Submitted") maybeSub

        matchesMaybeSubmission =
            \maybeSub quizGrade ->
                case maybeSub of
                    Just sub ->
                        quizGrade.assignment_submission_id == sub.id

                    Nothing ->
                        False

        grade =
            gd.assignmentGrades
                |> List.filter (matchesMaybeSubmission maybeSub)
                |> List.head
                |> maybeToStringWithDefault "Not graded" (\x -> toString x.points)

        maybeGdist =
            gd.assignmentGradeDistributions
                |> List.filter (\x -> x.assignment_slug == assignment.slug)
                |> List.head

        ( average, stddev ) =
            case maybeGdist of
                Just gdist ->
                    ( toString gdist.average, toString gdist.stddev )

                Nothing ->
                    ( "n/a", "n/a" )
    in
    Html.tr []
        [ td (shortDate assignment.closed_at)
        , td assignment.title
        , td subInfo
        , td grade
        , td average
        , td stddev
        ]
