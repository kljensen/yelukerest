module Dashboard.Views exposing (dashboard)

import Assignments.Model exposing (Assignment, AssignmentGrade, AssignmentGradeDistribution)
import Auth.Model exposing (CurrentUser)
import Auth.Views exposing (loginLink)
import Common.Views exposing (merge8)
import Html exposing (Html)
import Html.Attributes as Attrs
import Meetings.Model exposing (Meeting)
import Msgs exposing (Msg)
import Quizzes.Model exposing (Quiz, QuizGrade, QuizGradeDistribution)
import RemoteData exposing (WebData)


dashboard :
    WebData CurrentUser
    -> WebData (List Meeting)
    -> WebData (List Assignment)
    -> WebData (List AssignmentGrade)
    -> WebData (List AssignmentGradeDistribution)
    -> WebData (List Quiz)
    -> WebData (List QuizGrade)
    -> WebData (List QuizGradeDistribution)
    -> Html.Html Msg
dashboard currentUser meetings assignments assignmentGrades assignmentGradeDistributions quizzes quizGrades quizGradeDistributions =
    let
        userInfo =
            case currentUser of
                RemoteData.NotAsked ->
                    Html.text ""

                RemoteData.Loading ->
                    Html.text "Loading ..."

                RemoteData.Success currentUser ->
                    showDashboard currentUser

                RemoteData.Failure err ->
                    loginLink

        gradeTable =
            maybeShowGradeTable currentUser meetings assignments assignmentGrades assignmentGradeDistributions quizzes quizGrades quizGradeDistributions
    in
    Html.div []
        [ userInfo
        , gradeTable
        ]


showDashboard : CurrentUser -> Html.Html Msg
showDashboard currentUser =
    Html.table
        [ Attrs.class "dashboard" ]
        [ Html.tbody []
            [ dashboardRow "id" (toString currentUser.id)
            , dashboardRow "netid" currentUser.netid
            , dashboardRow "role" currentUser.role
            , dashboardRow "nickname" currentUser.nickname
            , dashboardRow "team_nickname" (Maybe.withDefault "none" currentUser.team_nickname)
            , dashboardRow "jwt" currentUser.jwt
            ]
        ]


dashboardRow : String -> String -> Html.Html Msg
dashboardRow label value =
    Html.tr []
        [ Html.td [] [ Html.text label ]
        , Html.td [] [ Html.text value ]
        ]


maybeShowGradeTable :
    WebData CurrentUser
    -> WebData (List Meeting)
    -> WebData (List Assignment)
    -> WebData (List AssignmentGrade)
    -> WebData (List AssignmentGradeDistribution)
    -> WebData (List Quiz)
    -> WebData (List QuizGrade)
    -> WebData (List QuizGradeDistribution)
    -> Html.Html Msg
maybeShowGradeTable currentUser meetings assignments assignmentGrades assignmentGradeDistributions quizzes quizGrades quizGradeDistributions =
    let
        neededData =
            merge8 currentUser meetings assignments assignmentGrades assignmentGradeDistributions quizzes quizGrades quizGradeDistributions
    in
    case neededData of
        RemoteData.Success ( xcurrentUser, xmeetings, xassignments, xassignmentGrades, xassignmentGradeDistributions, xquizzes, xquizGrades, xquizGradeDistributions ) ->
            showGradeTable xcurrentUser xmeetings xassignments xassignmentGrades xassignmentGradeDistributions xquizzes xquizGrades xquizGradeDistributions

        RemoteData.Failure e ->
            Html.div [] [ Html.text ("Failed to load data:" ++ toString e) ]

        _ ->
            Html.div [] [ Html.text "Loading..." ]


showGradeTable :
    CurrentUser
    -> List Meeting
    -> List Assignment
    -> List AssignmentGrade
    -> List AssignmentGradeDistribution
    -> List Quiz
    -> List QuizGrade
    -> List QuizGradeDistribution
    -> Html.Html Msg
showGradeTable currentUser meetings assignments assignmentGrades assignmentGradeDistributions quizzes quizGrades quizGradeDistributions =
    Html.div []
        [ showQuizGradeTable currentUser meetings quizzes quizGrades quizGradeDistributions
        , showAssignmentGradeTable currentUser assignments assignmentGrades assignmentGradeDistributions
        ]


showQuizGradeTable :
    CurrentUser
    -> List Meeting
    -> List Quiz
    -> List QuizGrade
    -> List QuizGradeDistribution
    -> Html.Html Msg
showQuizGradeTable currentUser meetings quizzes quizGrades quizGradeDistributions =
    Html.table
        [ Attrs.class "dashboard" ]
        [ Html.tbody []
            [ dashboardRow "Quiz Grade table" "goes here"
            ]
        ]


showAssignmentGradeTable :
    CurrentUser
    -> List Assignment
    -> List AssignmentGrade
    -> List AssignmentGradeDistribution
    -> Html.Html Msg
showAssignmentGradeTable currentUser assignments assignmentGrades assignmentGradeDistributions =
    Html.table
        [ Attrs.class "dashboard" ]
        [ Html.tbody []
            [ dashboardRow "Assignment Grade table" "goes here"
            ]
        ]
