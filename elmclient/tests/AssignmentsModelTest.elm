module AssignmentsModelTest exposing (tests)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentGradeException
        , AssignmentSubmission
        , AssignmentSubmissionAction(..)
        , NotSubmissibleReason(..)
        , SubmissibleState(..)
        , assignmentSubmissionAction
        , assignmentsDecoder
        , hasRepositoryTemplate
        , isSubmissible
        , notSubmissibleMessage
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
        , describe "repository template configuration"
            [ test "is read when the API sends it" <|
                \_ ->
                    Decode.decodeString assignmentsDecoder (assignmentJson templateFields)
                        |> Result.map (List.map hasRepositoryTemplate)
                        |> Expect.equal (Ok [ True ])
            , test "is absent when the API sends nulls" <|
                \_ ->
                    Decode.decodeString assignmentsDecoder (assignmentJson nullTemplateFields)
                        |> Result.map (List.map hasRepositoryTemplate)
                        |> Expect.equal (Ok [ False ])
            , test "is absent when the API does not send the fields at all" <|
                \_ ->
                    Decode.decodeString assignmentsDecoder (assignmentJson "")
                        |> Result.map (List.map hasRepositoryTemplate)
                        |> Expect.equal (Ok [ False ])
            , test "needs all three fields, not just some" <|
                \_ ->
                    hasRepositoryTemplate { baseAssignment | repository_template_provider = Just "github" }
                        |> Expect.equal False
            ]
        ]


assignmentJson : String -> String
assignmentJson extraFields =
    """[{"slug":"project-1","points_possible":10,"is_draft":false,"is_markdown":true,"is_team":false,"is_open":true,"title":"Project 1","body":"","closed_at":"2026-10-01T00:00:00Z","fields":[]"""
        ++ extraFields
        ++ "}]"


templateFields : String
templateFields =
    ""","repository_template_provider":"github","repository_template_full_name":"org/project-1-template","repository_url_field_slug":"repository_url" """


nullTemplateFields : String
nullTemplateFields =
    ""","repository_template_provider":null,"repository_template_full_name":null,"repository_url_field_slug":null"""


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
    , repository_template_provider = Nothing
    , repository_template_full_name = Nothing
    , repository_url_field_slug = Nothing
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
