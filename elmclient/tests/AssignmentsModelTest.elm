module AssignmentsModelTest exposing (tests)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentGradeException
        , AssignmentSubmission
        , AssignmentSubmissionAction(..)
        , MyRepository
        , NotSubmissibleReason(..)
        , SubmissibleState(..)
        , assignmentSubmissionAction
        , isSubmissible
        , myRepositoriesDecoder
        , notSubmissibleMessage
        , repositoryUrlForAssignment
        , submissionBelongsToUser
        )
import Auth.Model exposing (CurrentUser)
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)
import Time


tests : Test
tests =
    describe "Assignments.Model"
        [ describe "isSubmissible"
            [ test "allows an open individual assignment before close" <|
                \_ ->
                    isSubmissible (millis 1000) Nothing baseAssignment currentUser
                        |> Expect.equal (Submissible baseAssignment)
            , test "rejects a draft assignment before team checks" <|
                \_ ->
                    isSubmissible (millis 1000) Nothing { baseAssignment | is_draft = True, is_team = True } currentUser
                        |> Expect.equal (NotSubmissible IsDraft)
            , test "rejects a team assignment when the user has no team" <|
                \_ ->
                    isSubmissible (millis 1000) Nothing { baseAssignment | is_team = True } { currentUser | team_nickname = Nothing }
                        |> Expect.equal (NotSubmissible MissingTeam)
            , test "allows a closed assignment when an extension is still open" <|
                \_ ->
                    isSubmissible (millis 1000) (Just baseException) { baseAssignment | is_open = False } currentUser
                        |> Expect.equal (Submissible { baseAssignment | is_open = False })
            , test "rejects a closed assignment after an extension closes" <|
                \_ ->
                    isSubmissible (millis 3000) (Just baseException) { baseAssignment | is_open = False } currentUser
                        |> Expect.equal (NotSubmissible IsAfterClosed)
            , test "rejects a closed assignment without an extension" <|
                \_ ->
                    isSubmissible (millis 3000) Nothing { baseAssignment | is_open = False } currentUser
                        |> Expect.equal (NotSubmissible IsAfterClosed)
            ]
        , describe "assignmentSubmissionAction"
            [ test "begins an assignment when there is no existing submission" <|
                \_ ->
                    assignmentSubmissionAction (millis 1000) Nothing baseAssignment currentUser Nothing
                        |> Expect.equal (CanBeginAssignment baseAssignment)
            , test "updates an assignment when there is an existing submission" <|
                \_ ->
                    assignmentSubmissionAction (millis 1000) Nothing baseAssignment currentUser (Just baseSubmission)
                        |> Expect.equal (CanUpdateAssignment baseAssignment baseSubmission)
            , test "blocks beginning a team assignment when the user has no team" <|
                \_ ->
                    assignmentSubmissionAction (millis 1000) Nothing { baseAssignment | is_team = True } { currentUser | team_nickname = Nothing } Nothing
                        |> Expect.equal (CannotSubmitAssignment MissingTeam)
            , test "blocks an existing submission when the assignment is no longer writable" <|
                \_ ->
                    assignmentSubmissionAction (millis 3000) Nothing { baseAssignment | is_open = False } currentUser (Just baseSubmission)
                        |> Expect.equal (CannotSubmitAssignment IsAfterClosed)
            , test "allows updates when an extension is still open" <|
                \_ ->
                    assignmentSubmissionAction (millis 1000) (Just baseException) { baseAssignment | is_open = False } currentUser (Just baseSubmission)
                        |> Expect.equal (CanUpdateAssignment { baseAssignment | is_open = False } baseSubmission)
            ]
        , describe "notSubmissibleMessage"
            [ test "describes a draft assignment" <|
                \_ ->
                    notSubmissibleMessage IsDraft
                        |> Expect.equal "This assignment is still in draft mode and cannot yet be submitted."
            , test "describes a closed assignment" <|
                \_ ->
                    notSubmissibleMessage IsAfterClosed
                        |> Expect.equal "This assignment is now closed for submissions."
            , test "describes a missing team" <|
                \_ ->
                    notSubmissibleMessage MissingTeam
                        |> Expect.equal "This is a team assignment. You must join a team before you can submit. Please complete the team selection assignment first."
            ]
        , describe "submissionBelongsToUser"
            [ test "matches individual submissions by user id" <|
                \_ ->
                    { baseSubmission | user_id = Just currentUser.id }
                        |> submissionBelongsToUser currentUser
                        |> Expect.equal True
            , test "does not match individual submissions for another user" <|
                \_ ->
                    { baseSubmission | user_id = Just 99 }
                        |> submissionBelongsToUser currentUser
                        |> Expect.equal False
            , test "matches team submissions by team nickname" <|
                \_ ->
                    { baseSubmission | user_id = Nothing, team_nickname = currentUser.team_nickname }
                        |> submissionBelongsToUser currentUser
                        |> Expect.equal True
            , test "does not match team submissions for another team" <|
                \_ ->
                    { baseSubmission | user_id = Nothing, team_nickname = Just "team-b" }
                        |> submissionBelongsToUser currentUser
                        |> Expect.equal False
            , test "does not match team submissions when the user has no team" <|
                \_ ->
                    { baseSubmission | user_id = Nothing, team_nickname = Just "team-a" }
                        |> submissionBelongsToUser { currentUser | team_nickname = Nothing }
                        |> Expect.equal False
            ]
        , describe "myRepositoriesDecoder"
            [ test "decodes an individual github repository" <|
                \_ ->
                    Decode.decodeString myRepositoriesDecoder ("[" ++ repositoryJson ++ "]")
                        |> Expect.equal (Ok [ baseRepository ])
            , test "decodes the nullable columns of a team repository on an unknown forge" <|
                \_ ->
                    Decode.decodeString myRepositoriesDecoder
                        ("""[{"id": 8, "template_slug": "t", "label": "Starter", "assignment_slug": null,
                            "template_full_name": "org/starter", "is_team": true, "user_id": null,
                            "team_nickname": "team-a", "provider": "gitlab", "provider_repo_id": 5,
                            "provider_full_name": "org/starter-team-a", "repo_url": null,
                            "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z"}]""")
                        |> Expect.equal
                            (Ok
                                [ { baseRepository
                                    | assignment_slug = Nothing
                                    , is_team = True
                                    , user_id = Nothing
                                    , team_nickname = Just "team-a"
                                    , provider_full_name = "org/starter-team-a"
                                    , repo_url = Nothing
                                  }
                                ]
                            )
            ]
        , describe "repositoryUrlForAssignment"
            [ test "offers the repository created for this assignment" <|
                \_ ->
                    repositoryUrlForAssignment baseAssignment.slug [ baseRepository ]
                        |> Expect.equal baseRepository.repo_url
            , test "ignores repositories for other assignments or none" <|
                \_ ->
                    repositoryUrlForAssignment baseAssignment.slug [ { baseRepository | assignment_slug = Just "other" }, { baseRepository | assignment_slug = Nothing } ]
                        |> Expect.equal Nothing
            , test "ignores a repository without a browser URL" <|
                \_ ->
                    repositoryUrlForAssignment baseAssignment.slug [ { baseRepository | repo_url = Nothing } ]
                        |> Expect.equal Nothing
            , test "takes the first, which the fetch orders oldest first" <|
                \_ ->
                    repositoryUrlForAssignment baseAssignment.slug [ baseRepository, { baseRepository | repo_url = Just "https://github.com/org/second" } ]
                        |> Expect.equal baseRepository.repo_url
            ]
        ]


repositoryJson : String
repositoryJson =
    """{"id": 7, "template_slug": "t", "label": "Starter", "assignment_slug": "assignment-1",
        "template_full_name": "org/starter", "is_team": false, "user_id": 42,
        "team_nickname": null, "provider": "github", "provider_repo_id": 5,
        "provider_full_name": "org/starter-abc123", "repo_url": "https://github.com/org/starter-abc123",
        "created_at": "2026-09-01T00:00:00Z", "updated_at": "2026-09-01T00:00:00Z"}"""


baseRepository : MyRepository
baseRepository =
    { template_slug = "t"
    , label = "Starter"
    , assignment_slug = Just "assignment-1"
    , template_full_name = "org/starter"
    , repo_url = Just "https://github.com/org/starter-abc123"
    , is_team = False
    , user_id = Just 42
    , team_nickname = Nothing
    , provider_full_name = "org/starter-abc123"
    , created_at = millis 1788220800000
    }


currentUser : CurrentUser
currentUser =
    { id = 42
    , netid = "abc123"
    , jwt = "jwt"
    , role = "student"
    , nickname = "student"
    , team_nickname = Just "team-a"
    }


baseAssignment : Assignment
baseAssignment =
    { slug = "assignment-1"
    , points_possible = 10
    , is_draft = False
    , is_markdown = True
    , is_team = False
    , is_open = True
    , title = "Assignment 1"
    , body = "Body"
    , closed_at = millis 2000
    , fields = []
    }


baseSubmission : AssignmentSubmission
baseSubmission =
    { id = 1
    , assignment_slug = baseAssignment.slug
    , is_team = False
    , user_id = Just 42
    , team_nickname = Nothing
    , submitter_user_id = 42
    , created_at = millis 0
    , updated_at = millis 0
    , fields = []
    }


baseException : AssignmentGradeException
baseException =
    { id = 1
    , assignment_slug = baseAssignment.slug
    , is_team = False
    , user_id = Just 42
    , team_nickname = Nothing
    , fractional_credit = 1.0
    , closed_at = millis 2000
    , created_at = millis 0
    , updated_at = millis 0
    }


millis : Int -> Time.Posix
millis =
    Time.millisToPosix
