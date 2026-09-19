module AssignmentsViewsTest exposing (tests)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentSubmission
        , RepositoryError
        , RepositoryProgress(..)
        , RepositoryState(..)
        , RepositoryStatus
        )
import Assignments.Views
import Auth.Model exposing (CurrentUser)
import Dict
import Expect
import Html.Attributes
import Models exposing (TimeZone)
import Msgs exposing (Msg)
import RemoteData
import Test exposing (Test, describe, test)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Time exposing (ZoneName(..))


tests : Test
tests =
    describe "Assignments.Views"
        [ test "listView shows an assignment's points" <|
            \_ ->
                Assignments.Views.listView timeZone (RemoteData.Success [ baseAssignment ])
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "10 points" ]
        , test "detailView shows an assignment's points" <|
            \_ ->
                Assignments.Views.detailView
                    (RemoteData.Success currentUser)
                    (Just (millis 1000))
                    timeZone
                    (RemoteData.Success [ baseAssignment ])
                    (RemoteData.Success [])
                    (RemoteData.Success [])
                    Dict.empty
                    Dict.empty
                    baseAssignment.slug
                    Nothing
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "10 points" ]
        , describe "an assignment without a repository template"
            [ test "still begins with \"Begin assignment\"" <|
                \_ ->
                    detail baseAssignment Nothing Nothing
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.has [ Selector.text "Begin assignment" ]
            , test "and that button begins the assignment, not a repository" <|
                \_ ->
                    detail baseAssignment Nothing Nothing
                        |> Query.find [ Selector.tag "button" ]
                        |> Event.simulate Event.click
                        |> Event.expect (Msgs.OnBeginAssignment baseAssignment.slug)
            , test "shows the form once a submission exists" <|
                \_ ->
                    detail baseAssignment (Just submission) Nothing
                        |> Query.has [ Selector.tag "form" ]
            ]
        , describe "staff looking at an assignment with a repository template"
            [ test "see \"Begin assignment\", as students who have not started would" <|
                \_ ->
                    detailAs faculty templateAssignment Nothing Nothing
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.has [ Selector.text "Begin assignment" ]
            , test "are never told to check a repository" <|
                \_ ->
                    detailAs faculty templateAssignment Nothing Nothing
                        |> Query.hasNot [ Selector.text "Checking your repository…" ]
            ]
        , describe "an assignment with a repository template"
            [ test "offers to create the repository instead of beginning the assignment" <|
                \_ ->
                    detail templateAssignment Nothing (Just NotStarted)
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.has [ Selector.text "Create my repository" ]
            , test "and that button creates the repository" <|
                \_ ->
                    detail templateAssignment Nothing (Just NotStarted)
                        |> Query.find [ Selector.tag "button" ]
                        |> Event.simulate Event.click
                        |> Event.expect (Msgs.OnCreateRepository templateAssignment.slug)
            , test "never says \"Begin assignment\"" <|
                \_ ->
                    detail templateAssignment Nothing (Just NotStarted)
                        |> Query.hasNot [ Selector.text "Begin assignment" ]
            , test "a team assignment offers a team repository" <|
                \_ ->
                    detail { templateAssignment | is_team = True } Nothing (Just NotStarted)
                        |> Query.has [ Selector.text "Create our team repository" ]
            , test "still offers to create when a submission exists but no repository does" <|
                \_ ->
                    detail templateAssignment (Just submission) (Just NotStarted)
                        |> Query.has [ Selector.text "Create my repository" ]
            , test "waits while the status is unknown" <|
                \_ ->
                    detail templateAssignment Nothing Nothing
                        |> Expect.all
                            [ Query.has [ Selector.text "Checking your repository…" ]
                            , Query.hasNot [ Selector.tag "button" ]
                            ]
            , test "disables the button while creating" <|
                \_ ->
                    detail templateAssignment Nothing (Just Creating)
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.has [ Selector.disabled True, Selector.text "Creating your private repository…" ]
            , test "links to the repository while it is being copied" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Polling { since = millis 0, last = copying, inFlight = False, notBefore = Nothing }))
                        |> Expect.all
                            [ Query.has [ Selector.text "Starter files are being copied — usually under a minute." ]
                            , Query.find [ Selector.tag "a", Selector.attribute (Html.Attributes.href repoUrl) ] >> Query.has [ Selector.text repoUrl ]
                            ]
            , test "offers \"Check again\" once polling has given up" <|
                \_ ->
                    detail templateAssignment Nothing (Just (PollTimedOut copying))
                        |> Query.find [ Selector.tag "button" ]
                        |> Event.simulate Event.click
                        |> Event.expect (Msgs.OnLoadRepository templateAssignment.slug)
            , test "links to the finished repository" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Done ready))
                        |> Query.find [ Selector.tag "a", Selector.containing [ Selector.text "Open your repository" ] ]
                        |> Query.has [ Selector.attribute (Html.Attributes.href repoUrl) ]
            , test "and shows the form beneath it once the submission is back" <|
                \_ ->
                    detail templateAssignment (Just submission) (Just (Done ready))
                        |> Expect.all
                            [ Query.has [ Selector.text "Open your repository" ]
                            , Query.has [ Selector.tag "form" ]
                            ]
            , test "sends the student to join the organization when it knows where" <|
                \_ ->
                    detail templateAssignment Nothing (Just (blocked needsOrgJoin))
                        |> Query.find [ Selector.tag "a", Selector.containing [ Selector.text "Join the course GitHub organization" ] ]
                        |> Query.has [ Selector.attribute (Html.Attributes.href "https://github.com/orgs/org/invitation") ]
            , test "says so when the student cancelled the join" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Blocked { status = needsOrgJoin, notBefore = Nothing, joinCancelled = True }))
                        |> Expect.all
                            [ Query.has [ Selector.text "You cancelled the GitHub authorization. Try again when ready." ]
                            , Query.has [ Selector.text "Join the course GitHub organization" ]
                            ]
            , test "or explains the invitation when it does not" <|
                \_ ->
                    detail templateAssignment Nothing (Just (blocked { needsOrgJoin | joinUrl = Nothing }))
                        |> Query.has [ Selector.text "You need to accept the GitHub organization invitation first (check your email), then try again." ]
            , test "points a missing GitHub username at the teaching staff" <|
                \_ ->
                    detail templateAssignment Nothing (Just (blocked { state = NeedsGithubLink, repoUrl = Nothing, joinUrl = Nothing }))
                        |> Query.has [ Selector.text "We don't have a working GitHub username for you; tell the teaching staff." ]
            , test "offers to resume an interrupted create" <|
                \_ ->
                    detail templateAssignment Nothing (Just (failed { code = "provisioning_interrupted", retryable = True, httpStatus = 409, retryAfterSeconds = Nothing }))
                        |> Query.find [ Selector.tag "button", Selector.containing [ Selector.text "Resume" ] ]
                        |> Event.simulate Event.click
                        |> Event.expect (Msgs.OnCreateRepository templateAssignment.slug)
            , test "offers to try a retryable failure again" <|
                \_ ->
                    detail templateAssignment Nothing (Just (failed { code = "github_unavailable", retryable = True, httpStatus = 502, retryAfterSeconds = Nothing }))
                        |> Query.find [ Selector.tag "button", Selector.containing [ Selector.text "Try again" ] ]
                        |> Event.simulate Event.click
                        |> Event.expect (Msgs.OnLoadRepository templateAssignment.slug)
            , test "a rate limit turns \"Try again\" off and says for how long" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Failed { error = rateLimited, notBefore = Just (millis 18000) }))
                        |> Expect.all
                            [ Query.has [ Selector.text "Too many requests. Please wait before trying again." ]
                            , Query.find [ Selector.tag "button" ] >> Query.has [ Selector.disabled True, Selector.text "Try again" ]
                            , Query.has [ Selector.text " You can try again in 17 s." ]
                            ]
            , test "a rate limit under a prerequisite turns its \"Try again\" off too" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Blocked { status = needsOrgJoin, notBefore = Just (millis 18000), joinCancelled = False }))
                        |> Expect.all
                            [ Query.has [ Selector.text "You need to join the course GitHub organization before a repository can be created for you." ]
                            , Query.find [ Selector.tag "button" ] >> Query.has [ Selector.disabled True ]
                            ]
            , test "the button comes back once the hold is up" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Failed { error = rateLimited, notBefore = Just (millis 1000) }))
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.hasNot [ Selector.disabled True ]
            , test "an expired session says to sign in again, with no retry" <|
                \_ ->
                    detail templateAssignment Nothing (Just (failed { code = "session_expired", retryable = False, httpStatus = 401, retryAfterSeconds = Nothing }))
                        |> Expect.all
                            [ Query.has [ Selector.text "Your session has expired. Reload the page and sign in again." ]
                            , Query.hasNot [ Selector.tag "button" ]
                            ]
            , test "names the code of a conflict and offers no retry" <|
                \_ ->
                    detail templateAssignment Nothing (Just (failed { code = "submission_conflict", retryable = False, httpStatus = 409, retryAfterSeconds = Nothing }))
                        |> Expect.all
                            [ Query.has [ Selector.text "Please tell the teaching staff and mention the code \"submission_conflict\"." ]
                            , Query.hasNot [ Selector.tag "button" ]
                            ]
            , test "a closed assignment offers no repository at all" <|
                \_ ->
                    detail { templateAssignment | is_open = False } Nothing (Just NotStarted)
                        |> Expect.all
                            [ Query.has [ Selector.text "This assignment is now closed for submissions." ]
                            , Query.hasNot [ Selector.tag "button" ]
                            ]
            ]
        ]


{-| The detail page for one assignment, the student's submission to it if
any, and what is known about its repository. The clock reads one second
past the epoch.
-}
detail : Assignment -> Maybe AssignmentSubmission -> Maybe RepositoryProgress -> Query.Single Msg
detail =
    detailAs currentUser


detailAs : CurrentUser -> Assignment -> Maybe AssignmentSubmission -> Maybe RepositoryProgress -> Query.Single Msg
detailAs user assignment maybeSubmission maybeProgress =
    Assignments.Views.detailView
        (RemoteData.Success user)
        (Just (millis 1000))
        timeZone
        (RemoteData.Success [ assignment ])
        (RemoteData.Success
            (maybeSubmission
                |> Maybe.map (\s -> [ { s | assignment_slug = assignment.slug } ])
                |> Maybe.withDefault []
            )
        )
        (RemoteData.Success [])
        Dict.empty
        (maybeProgress |> Maybe.map (Dict.singleton assignment.slug) |> Maybe.withDefault Dict.empty)
        assignment.slug
        Nothing
        |> Query.fromHtml


timeZone : TimeZone
timeZone =
    { zone = Time.utc, zoneName = Name "utc" }


currentUser : CurrentUser
currentUser =
    { id = 42
    , netid = "abc123"
    , jwt = "jwt"
    , role = "student"
    , nickname = "student"
    , team_nickname = Just "team-a"
    }


templateAssignment : Assignment
templateAssignment =
    { baseAssignment
        | slug = "project-1"
        , repository_template_provider = Just "github"
        , repository_template_full_name = Just "org/project-1-template"
        , repository_url_field_slug = Just "repository_url"
    }


submission : AssignmentSubmission
submission =
    { id = 1
    , assignment_slug = baseAssignment.slug
    , is_team = False
    , user_id = Just currentUser.id
    , team_nickname = Nothing
    , submitter_user_id = currentUser.id
    , created_at = millis 0
    , updated_at = millis 0
    , fields = []
    }


repoUrl : String
repoUrl =
    "https://github.com/org/project-1-abc123"


ready : RepositoryStatus
ready =
    { state = Ready, repoUrl = Just repoUrl, joinUrl = Nothing }


copying : RepositoryStatus
copying =
    { ready | state = Copying }


needsOrgJoin : RepositoryStatus
needsOrgJoin =
    { state = NeedsOrgJoin, repoUrl = Nothing, joinUrl = Just "https://github.com/orgs/org/invitation" }


rateLimited : RepositoryError
rateLimited =
    { code = "rate_limited", retryable = True, httpStatus = 429, retryAfterSeconds = Just 17 }


blocked : RepositoryStatus -> RepositoryProgress
blocked status =
    Blocked { status = status, notBefore = Nothing, joinCancelled = False }


failed : RepositoryError -> RepositoryProgress
failed error =
    Failed { error = error, notBefore = Nothing }


faculty : CurrentUser
faculty =
    { currentUser | id = 1, netid = "prof1", role = "faculty", nickname = "prof" }


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


millis : Int -> Time.Posix
millis =
    Time.millisToPosix
