module Assignments.Commands exposing (fetchAssignmentSubmissions, fetchAssignments)

import Assignments.Model exposing (assignmentSubmissionsDecoder, assignmentsDecoder)
import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)
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
