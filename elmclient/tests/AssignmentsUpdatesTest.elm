module AssignmentsUpdatesTest exposing (tests)

import Assignments.Commands exposing (fetchMyRepositoriesUrl)
import Assignments.Updates exposing (onSubmitAssignmentFieldSubmissionsResponse, studentEnteringAssignment)
import Auth.Model exposing (CurrentUser)
import Dict
import Expect
import Http
import Models exposing (Route(..))
import RemoteData
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Assignments.Updates"
        [ describe "onSubmitAssignmentFieldSubmissionsResponse"
            [ test "a successful save keeps the inputs" <|
                \_ ->
                    onSubmitAssignmentFieldSubmissionsResponse slug (RemoteData.Success []) pendingSave
                        |> Tuple.first
                        |> .assignmentFieldSubmissionInputs
                        |> Expect.equal pendingSave.assignmentFieldSubmissionInputs
            , test "a successful save clears the pending request and asks for a refetch" <|
                \_ ->
                    onSubmitAssignmentFieldSubmissionsResponse slug (RemoteData.Success []) pendingSave
                        |> Tuple.mapFirst .pendingAssignmentFieldSubmissionRequests
                        |> Expect.equal ( Dict.empty, True )
            , test "a failed save changes nothing" <|
                \_ ->
                    onSubmitAssignmentFieldSubmissionsResponse slug (RemoteData.Failure Http.NetworkError) pendingSave
                        |> Expect.equal ( pendingSave, False )
            ]

        -- The route-entry refetch is what keeps the offered repository fresh
        -- and what recovers from a failed first fetch: nothing else retries.
        , describe "studentEnteringAssignment"
            [ test "a student entering an assignment page gets a refetch" <|
                \_ ->
                    studentEnteringAssignment (AssignmentDetailRoute slug) (RemoteData.Success student)
                        |> Expect.equal (Just student)
            , test "faculty entering an assignment page do not" <|
                \_ ->
                    studentEnteringAssignment (AssignmentDetailRoute slug) (RemoteData.Success { student | role = "faculty" })
                        |> Expect.equal Nothing
            , test "a student entering another page does not" <|
                \_ ->
                    studentEnteringAssignment AssignmentListRoute (RemoteData.Success student)
                        |> Expect.equal Nothing
            , test "nobody signed in does not" <|
                \_ ->
                    studentEnteringAssignment (AssignmentDetailRoute slug) (RemoteData.Failure (Http.BadStatus 401))
                        |> Expect.equal Nothing
            ]
        , test "repositories are fetched oldest first, so the one offered is stable" <|
            \_ ->
                fetchMyRepositoriesUrl
                    |> Expect.equal "/rest/my_repositories?order=created_at.asc"
        ]


slug : String
slug =
    "assignment-1"


pendingSave :
    { pendingAssignmentFieldSubmissionRequests : Dict.Dict String (RemoteData.WebData (List a))
    , assignmentFieldSubmissionInputs : Dict.Dict ( Int, String ) String
    }
pendingSave =
    { pendingAssignmentFieldSubmissionRequests = Dict.singleton slug RemoteData.Loading
    , assignmentFieldSubmissionInputs = Dict.singleton ( 1, "repo-url" ) "https://github.com/org/starter-abc123"
    }


student : CurrentUser
student =
    { id = 42
    , netid = "abc123"
    , jwt = "jwt"
    , role = "student"
    , nickname = "student"
    , team_nickname = Nothing
    }
