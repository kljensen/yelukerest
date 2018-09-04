module Assignments.Commands exposing (createAssignmentSubmission, fetchAssignmentSubmissions, fetchAssignments, sendAssignmentFieldSubmissions)

import Assignments.Model
    exposing
        ( AssignmentSlug
        , assignmentFieldSubmissionsDecoder
        , assignmentSubmissionDecoder
        , assignmentSubmissionsDecoder
        , assignmentsDecoder
        )
import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser, JWT)
import Http
import Json.Encode as Encode
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
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
                ++ toString currentUser.id
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
                    ++ toString currentUser.id
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
                , expect = Http.expectJson assignmentSubmissionDecoder
                , withCredentials = False
                , body = Http.jsonBody (Encode.object [ ( "assignment_slug", Encode.string slug ) ])
                }
    in
    request
        |> RemoteData.sendRequest
        |> Cmd.map (Msgs.OnBeginAssignmentComplete slug)


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
        |> List.map encodeAFS
        |> Encode.list


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

        request =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/assignment_field_submissions"
                , timeout = Nothing
                , expect = Http.expectJson assignmentFieldSubmissionsDecoder
                , withCredentials = False
                , body = Http.jsonBody (encodeAFSList valueTuples)
                }
    in
    request
        |> RemoteData.sendRequest
        |> Cmd.map (Msgs.OnSubmitAssignmentFieldSubmissionsResponse assignmentSlug)
