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
import Round


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
    let
        row =
            dashboardRow []
    in
    Html.div []
        [ Html.h2 [] [ Html.text "Your account info" ]
        , Html.table [ Attrs.class "dashboard" ]
            [ Html.tbody []
                [ row "id" (toString currentUser.id)
                , row "netid" currentUser.netid
                , row "role" currentUser.role
                , row "nickname" currentUser.nickname
                , row "team_nickname" (Maybe.withDefault "none" currentUser.team_nickname)
                , dashboardRow [ Attrs.class "secondary" ] "jwt" currentUser.jwt
                ]
            ]
        ]


dashboardRow : List (Html.Attribute Msg) -> String -> String -> Html.Html Msg
dashboardRow attrs label value =
    Html.tr []
        [ Html.td attrs [ Html.text label ]
        , Html.td attrs [ Html.text value ]
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
    Html.thead []
        [ Html.tr []
            [ th "Date"
            , th2 "Meeting"
            , th2 "Status"
            , th "Grade"
            , th2 "Points Possible"
            , th "Class Average"
            , th2 "Class Stddev"
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
    -- DateFormat.format "%d\u{00A0}%b" d
    "foo"


td : String -> Html.Html Msg
td x =
    Html.td [] [ Html.text x ]


td2 : String -> Html.Html Msg
td2 x =
    Html.td [ Attrs.class "secondary" ] [ Html.text x ]


th : String -> Html.Html Msg
th x =
    Html.th [] [ Html.text x ]


th2 : String -> Html.Html Msg
th2 x =
    Html.th [ Attrs.class "secondary" ] [ Html.text x ]


showGradeForQuiz : QuizGradeData a -> Quiz -> Meeting -> Html.Html Msg
showGradeForQuiz gd quiz meeting =
    let
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
                |> maybeToStringWithDefault "Not graded" (\x -> prettyFloat x.points)

        maybeGdist =
            gd.quizGradeDistributions
                |> List.filter (\x -> x.quiz_id == quiz.id)
                |> List.head

        ( average, stddev ) =
            case maybeGdist of
                Just gdist ->
                    ( prettyFloat gdist.average, prettyFloat gdist.stddev )

                Nothing ->
                    ( "n/a", "n/a" )
    in
    Html.tr []
        [ td (shortDate meeting.begins_at)
        , td2 meeting.title
        , td2 qs
        , td grade
        , td2 (toString quiz.points_possible)
        , td average
        , td2 stddev
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
    Html.thead []
        [ Html.tr []
            [ th2 "Date"
            , th "Assignment"
            , th2 "Status"
            , th "Grade"
            , th2 "Points Possible"
            , th "Class Average"
            , th2 "Class Stddev"
            ]
        ]


prettyFloat : Float -> String
prettyFloat x =
    Round.round 2 x


showGradeForAssignment : AssignmentGradeData a -> Assignment -> Html.Html Msg
showGradeForAssignment gd assignment =
    let
        maybeSub =
            gd.assignmentSubmissions
                |> List.filter (submissionBelongsToUser gd.currentUser)
                |> List.filter (\x -> x.assignment_slug == assignment.slug)
                |> List.head

        subInfo =
            maybeToStringWithDefault "Not submitted" (\x -> "Submitted") maybeSub

        {- Have to be careful because users in the 'faculty' role
           will have more assignmentSubmissions than just their own
        -}
        matchesMaybeSubmission =
            \maybeSub assignmentGrade ->
                case maybeSub of
                    Just sub ->
                        assignmentGrade.assignment_submission_id == sub.id

                    Nothing ->
                        False

        grade =
            gd.assignmentGrades
                |> List.filter (matchesMaybeSubmission maybeSub)
                |> List.head
                |> maybeToStringWithDefault "Not graded" (\x -> prettyFloat x.points)

        maybeGdist =
            gd.assignmentGradeDistributions
                |> List.filter (\x -> x.assignment_slug == assignment.slug)
                |> List.head

        ( average, stddev ) =
            case maybeGdist of
                Just gdist ->
                    ( prettyFloat gdist.average, prettyFloat gdist.stddev )

                Nothing ->
                    ( "n/a", "n/a" )
    in
    Html.tr []
        [ td2 (shortDate assignment.closed_at)
        , td assignment.title
        , td2 subInfo
        , td grade
        , td2 (toString assignment.points_possible)
        , td average
        , td2 stddev
        ]
