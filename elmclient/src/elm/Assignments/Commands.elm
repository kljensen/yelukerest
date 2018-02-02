module Assignments.Commands exposing (createAssignmentSubmission, fetchAssignmentSubmissions, fetchAssignments)

import Assignments.Model exposing (AssignmentSlug, assignmentSubmissionDecoder, assignmentSubmissionsDecoder, assignmentsDecoder)
import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser, JWT)
import Http
import Json.Encode as Encode
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


fetchAssignments : WebData CurrentUser -> Cmd Msg
fetchAssignments currentUser =
    fetchForCurrentUser currentUser fetchAssignmentsUrl assignmentsDecoder Msgs.OnFetchAssignments


fetchAssignmentsUrl : String
fetchAssignmentsUrl =
    "/rest/assignments?order=closed_at&select=*,fields:assignment_fields(*)"


fetchAssignmentSubmissions : WebData CurrentUser -> Cmd Msg
fetchAssignmentSubmissions currentUser =
    fetchForCurrentUser currentUser fetchAssignmentSubmissionsUrl assignmentSubmissionsDecoder Msgs.OnFetchAssignmentSubmissions


fetchAssignmentSubmissionsUrl : String
fetchAssignmentSubmissionsUrl =
    "/rest/assignment_submissions?select=*,fields:assignment_field_submissions(*)"


createAssignmentSubmission : JWT -> AssignmentSlug -> Cmd Msg
createAssignmentSubmission jwt slug =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
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
        |> Cmd.map Msgs.OnBeginAssignmentComplete
