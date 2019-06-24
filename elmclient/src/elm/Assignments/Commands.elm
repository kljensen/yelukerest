module Assignments.Commands exposing
    ( createAssignmentSubmission
    , fetchAssignmentGradeDistributions
    , fetchAssignmentGrades
    , fetchAssignmentSubmissions
    , fetchAssignments
    , sendAssignmentFieldSubmissions
    )

import Assignments.Model
    exposing
        ( AssignmentGrade
        , AssignmentGradeDistribution
        , AssignmentSlug
        , assignmentFieldSubmissionsDecoder
        , assignmentGradeDistributionsDecoder
        , assignmentGradesDecoder
        , assignmentSubmissionDecoder
        , assignmentSubmissionsDecoder
        , assignmentsDecoder
        )
import Auth.Commands exposing (fetchForCurrentUser, sendRequestWithJWT)
import Auth.Model exposing (CurrentUser, JWT)
import Http
import Json.Encode as Encode
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import String
import Tuple


fetchAssignments : CurrentUser -> Cmd Msg
fetchAssignments currentUser =
    fetchForCurrentUser currentUser fetchAssignmentsUrl assignmentsDecoder Msgs.OnFetchAssignments


fetchAssignmentsUrl : String
fetchAssignmentsUrl =
    "/rest/assignments?order=closed_at&select=*,fields:assignment_fields(*)"


fetchAssignmentSubmissions : CurrentUser -> Cmd Msg
fetchAssignmentSubmissions currentUser =
    fetchForCurrentUser currentUser (fetchAssignmentSubmissionsUrl currentUser) assignmentSubmissionsDecoder Msgs.OnFetchAssignmentSubmissions


fetchAssignmentSubmissionsUrl : CurrentUser -> String
fetchAssignmentSubmissionsUrl currentUser =
    let
        base =
            "/rest/assignment_submissions"

        select =
            "select=*,fields:assignment_field_submissions(*)"

        defaultQuery =
            base
                ++ "?user_id=eq."
                ++ String.fromInt currentUser.id
                ++ "&"
                ++ select
    in
    case currentUser.team_nickname of
        Just nickname ->
            if nickname == "" then
                defaultQuery

            else
                base
                    ++ "?or=(user_id.eq."
                    ++ String.fromInt currentUser.id
                    ++ ",team_nickname.eq."
                    ++ nickname
                    ++ ")&"
                    ++ select

        Nothing ->
            defaultQuery


createAssignmentSubmission : JWT -> AssignmentSlug -> Cmd Msg
createAssignmentSubmission jwt slug =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation"
            , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]

        request =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/assignment_submissions"
                , timeout = Nothing
                , tracker = Nothing
                , expect = Http.expectJson (RemoteData.fromResult >> Msgs.OnBeginAssignmentComplete slug) assignmentSubmissionDecoder
                , body = Http.jsonBody (Encode.object [ ( "assignment_slug", Encode.string slug ) ])
                }
    in
    request


encodeAFS : ( Int, String ) -> Encode.Value
encodeAFS tup =
    -- Encode the assignment field submission into a minimal
    -- json format to be sent to the server.
    Encode.object
        [ ( "assignment_field_id", Encode.int (Tuple.first tup) )
        , ( "body", Encode.string (Tuple.second tup) )
        ]


encodeAFSList : List ( Int, String ) -> Encode.Value
encodeAFSList valueTuples =
    valueTuples
        |> Encode.list encodeAFS


sendAssignmentFieldSubmissions : JWT -> String -> List ( Int, String ) -> Cmd Msg
sendAssignmentFieldSubmissions jwt assignmentSlug valueTuples =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation"
            , Http.header "Prefer" "resolution=merge-duplicates"

            -- , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]

        obj =
            List.map

        msg =
            Msgs.OnSubmitAssignmentFieldSubmissionsResponse assignmentSlug

        request =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/assignment_field_submissions"
                , timeout = Nothing
                , tracker = Nothing
                , expect = Http.expectJson (RemoteData.fromResult >> msg) assignmentFieldSubmissionsDecoder
                , body = Http.jsonBody (encodeAFSList valueTuples)
                }
    in
    request


{-| Notice that there is no way to restrict this
set of returned grades to only those owned by the
current user via the API. So, for user with the
'faculty' role, more assignment grades will come
back than are owned by the user.
-}
fetchAssignmentGrades : CurrentUser -> Cmd Msg
fetchAssignmentGrades currentUser =
    fetchForCurrentUser currentUser fetchAssignmentGradesUrl assignmentGradesDecoder Msgs.OnFetchAssignmentGrades


fetchAssignmentGradesUrl : String
fetchAssignmentGradesUrl =
    "/rest/assignment_grades"


fetchAssignmentGradeDistributions : CurrentUser -> Cmd Msg
fetchAssignmentGradeDistributions currentUser =
    fetchForCurrentUser currentUser fetchAssignmentGradeDistributionsUrl assignmentGradeDistributionsDecoder Msgs.OnFetchAssignmentGradeDistributions


fetchAssignmentGradeDistributionsUrl : String
fetchAssignmentGradeDistributionsUrl =
    "/rest/assignment_grade_distributions"
