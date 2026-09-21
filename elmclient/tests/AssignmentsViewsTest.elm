module AssignmentsViewsTest exposing (tests)

import Assignments.Model
    exposing
        ( Assignment
        , AssignmentField
        , AssignmentFieldSubmission
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
import Http
import Models exposing (TimeZone)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
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
                    Dict.empty
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
                        |> repositorySection
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.has [ Selector.text "Create my repository" ]
            , test "and that button creates the repository" <|
                \_ ->
                    detail templateAssignment Nothing (Just NotStarted)
                        |> repositorySection
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

            -- Part B: the answers. The form is there from the start, minus
            -- the repository URL field, which the repository fills in.
            , test "shows the form for the other fields before any submission exists" <|
                \_ ->
                    detail templateAssignment Nothing (Just NotStarted)
                        |> Query.find [ Selector.tag "form" ]
                        |> Query.has [ Selector.tag "input", Selector.attribute (Html.Attributes.name "notes") ]
            , test "never renders the repository URL field as an input" <|
                \_ ->
                    detail templateAssignment Nothing (Just NotStarted)
                        |> Query.hasNot [ Selector.tag "input", Selector.attribute (Html.Attributes.name "repository_url") ]
            , test "nor once a submission exists" <|
                \_ ->
                    detail templateAssignment (Just submission) (Just (Done ready))
                        |> Query.hasNot [ Selector.tag "input", Selector.attribute (Html.Attributes.name "repository_url") ]
            , test "a submit before any submission exists begins the assignment and sends the answers as one" <|
                \_ ->
                    detail templateAssignment Nothing (Just NotStarted)
                        |> Query.find [ Selector.tag "form" ]
                        |> Event.simulate Event.submit
                        |> Event.expect (Msgs.OnBeginAndSubmitAssignmentFieldSubmissions templateAssignment.slug)
            , test "and what is typed there is a draft for the assignment" <|
                \_ ->
                    detail templateAssignment Nothing (Just NotStarted)
                        |> Query.find [ Selector.tag "input", Selector.attribute (Html.Attributes.name "notes") ]
                        |> Event.simulate (Event.input "hello")
                        |> Event.expect (Msgs.OnUpdateAssignmentDraftInput templateAssignment.slug "notes" "hello")
            , test "with a submission, what is typed is held under its id" <|
                \_ ->
                    detail templateAssignment (Just submission) (Just NotStarted)
                        |> Query.find [ Selector.tag "form" ]
                        |> Query.find [ Selector.tag "input", Selector.attribute (Html.Attributes.name "notes") ]
                        |> Event.simulate (Event.input "hello")
                        |> Event.expect (Msgs.OnUpdateAssignmentFieldSubmissionInput submission.id "notes" "hello")
            , test "shows the draft in its input" <|
                \_ ->
                    detailTyped currentUser Nothing Dict.empty (Dict.singleton templateAssignment.slug (Dict.singleton "notes" "so far")) templateAssignment Nothing (Just NotStarted)
                        |> Query.find [ Selector.tag "form" ]
                        |> Query.find [ Selector.tag "input", Selector.attribute (Html.Attributes.name "notes") ]
                        |> Query.has [ Selector.attribute (Html.Attributes.value "so far") ]
            , test "and, once the submission is there, what was adopted under its id" <|
                \_ ->
                    detailTyped currentUser Nothing (Dict.singleton ( submission.id, "notes" ) "so far") Dict.empty templateAssignment (Just submission) (Just (Done ready))
                        |> Query.find [ Selector.tag "form" ]
                        |> Query.find [ Selector.tag "input", Selector.attribute (Html.Attributes.name "notes") ]
                        |> Query.has [ Selector.attribute (Html.Attributes.value "so far") ]
            , test "Submit is off while the answers are being sent" <|
                \_ ->
                    detailWithPending (Just RemoteData.Loading) templateAssignment Nothing (Just NotStarted)
                        |> Query.find [ Selector.tag "form" ]
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.has [ Selector.disabled True ]
            , test "and says so when they could not be saved" <|
                \_ ->
                    detailWithPending (Just (RemoteData.Failure Http.NetworkError)) templateAssignment (Just submission) (Just NotStarted)
                        |> Query.find [ Selector.tag "form" ]
                        |> Expect.all
                            [ Query.has [ Selector.text "Could not save your answers. Try again." ]
                            , Query.find [ Selector.tag "button" ] >> Query.hasNot [ Selector.disabled True ]
                            ]
            , test "the old page's Submit is off while sending too" <|
                \_ ->
                    detailWithPending (Just RemoteData.Loading) baseAssignment (Just submission) Nothing
                        |> Query.find [ Selector.tag "form" ]
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.has [ Selector.disabled True ]
            , test "a submit on an existing submission updates it as before" <|
                \_ ->
                    detail templateAssignment (Just submission) (Just NotStarted)
                        |> Query.find [ Selector.tag "form" ]
                        |> Event.simulate Event.submit
                        |> Event.expect (Msgs.OnSubmitAssignmentFieldSubmissions { submission | assignment_slug = templateAssignment.slug })
            , test "the form is there whatever the repository is doing" <|
                \_ ->
                    detail templateAssignment Nothing (Just (failed { code = "github_unavailable", retryable = True, httpStatus = 502, retryAfterSeconds = Nothing }))
                        |> Query.has [ Selector.tag "form" ]
            , test "an assignment with only the repository field has no form" <|
                \_ ->
                    detail repoOnlyAssignment Nothing (Just NotStarted)
                        |> Expect.all
                            [ Query.hasNot [ Selector.tag "form" ]
                            , Query.has [ Selector.text "Create my repository" ]
                            ]
            , test "and says so once the repository is ready" <|
                \_ ->
                    detail repoOnlyAssignment (Just submission) (Just (Done ready))
                        |> Expect.all
                            [ Query.hasNot [ Selector.tag "form" ]
                            , Query.has [ Selector.text "Nothing else to submit here — continue your work in GitHub." ]
                            ]
            , test "but not before" <|
                \_ ->
                    detail repoOnlyAssignment Nothing (Just Creating)
                        |> Query.hasNot [ Selector.text "Nothing else to submit here — continue your work in GitHub." ]
            , test "the existing submission shows the recorded repository as a link" <|
                \_ ->
                    detail templateAssignment (Just (submissionWith urlField)) (Just (Done ready))
                        |> Query.find [ Selector.tag "a", Selector.attribute (Html.Attributes.href repoUrl), Selector.containing [ Selector.text repoUrl ] ]
                        |> Query.has [ Selector.tag "a" ]
            , test "or \"not yet\" when nothing is recorded" <|
                \_ ->
                    detail templateAssignment (Just submission) (Just NotStarted)
                        |> Query.has [ Selector.text "not yet" ]

            -- Part C: a repository made some other way. The URL is theirs
            -- and the server has none on record, so the old page stays.
            , test "a URL the student recorded, with no repository on record, keeps the old page" <|
                \_ ->
                    detail templateAssignment (Just (submissionWith urlField)) (Just NotStarted)
                        |> Expect.all
                            [ Query.hasNot [ Selector.text "Create my repository" ]
                            , Query.hasNot [ Selector.text "not yet" ]
                            , Query.find [ Selector.tag "form" ] >> Query.has [ Selector.tag "input", Selector.attribute (Html.Attributes.name "repository_url") ]
                            ]
            , test "but once the server has one on record the field is the repository's" <|
                \_ ->
                    detail templateAssignment (Just (submissionWith urlField)) (Just (Done ready))
                        |> Expect.all
                            [ Query.has [ Selector.text "Repository recorded." ]
                            , Query.hasNot [ Selector.tag "input", Selector.attribute (Html.Attributes.name "repository_url") ]
                            ]
            , test "and while the server is still being asked, the new page is shown" <|
                \_ ->
                    detail templateAssignment (Just (submissionWith urlField)) (Just Checking)
                        |> Query.has [ Selector.text "Checking your repository…" ]
            , test "waits while the status is unknown" <|
                \_ ->
                    detail templateAssignment Nothing Nothing
                        |> Expect.all
                            [ Query.has [ Selector.text "Checking your repository…" ]
                            , repositorySection >> Query.hasNot [ Selector.tag "button" ]
                            ]
            , test "disables the button while creating" <|
                \_ ->
                    detail templateAssignment Nothing (Just Creating)
                        |> repositorySection
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.has [ Selector.disabled True, Selector.text "Creating your repository…" ]
            , test "links to the repository while it is being copied" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Polling { since = millis 0, last = copying, inFlight = False, notBefore = Nothing }))
                        |> Expect.all
                            [ Query.has [ Selector.text "Preparing your repository's starter files — usually under a minute." ]
                            , Query.find [ Selector.tag "a", Selector.attribute (Html.Attributes.href repoUrl) ] >> Query.has [ Selector.text repoUrl ]
                            ]
            , test "offers \"Check again\" once polling has given up" <|
                \_ ->
                    detail templateAssignment Nothing (Just (PollTimedOut copying))
                        |> Query.find [ Selector.tag "button", Selector.containing [ Selector.text "Check again" ] ]
                        |> Event.simulate Event.click
                        |> Event.expect (Msgs.OnLoadRepository templateAssignment.slug)
            , test "and says the checks are paused" <|
                \_ ->
                    detail templateAssignment Nothing (Just (PollTimedOut copying))
                        |> Query.has [ Selector.text "Status checks paused. " ]
            , test "links to the finished repository" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Done ready))
                        |> Query.find [ Selector.tag "a", Selector.containing [ Selector.text "Open your repository" ] ]
                        |> Query.has [ Selector.attribute (Html.Attributes.href repoUrl) ]
            , test "and says it is recorded" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Done ready))
                        |> Query.has [ Selector.text "Repository recorded." ]
            , test "a team's finished repository is \"our team repository\"" <|
                \_ ->
                    detail { templateAssignment | is_team = True } Nothing (Just (Done ready))
                        |> Query.has [ Selector.text "Open our team repository" ]
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
            , test "offers to connect a GitHub account when it knows where" <|
                \_ ->
                    detail templateAssignment Nothing (Just (blocked { state = NeedsGithubLink, repoUrl = Nothing, joinUrl = Just "/auth/github/join?assignment_slug=project-1" }))
                        |> Expect.all
                            [ Query.find [ Selector.tag "a", Selector.containing [ Selector.text "Connect your GitHub account" ] ] >> Query.has [ Selector.attribute (Html.Attributes.href "/auth/github/join?assignment_slug=project-1") ]
                            , Query.has [ Selector.text "This also joins the course GitHub organization." ]
                            ]
            , test "points a missing GitHub account at the teaching staff otherwise" <|
                \_ ->
                    detail templateAssignment Nothing (Just (blocked { state = NeedsGithubLink, repoUrl = Nothing, joinUrl = Nothing }))
                        |> Query.has [ Selector.text "We don't have a GitHub account on file for you; tell the teaching staff." ]
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
                            , repositorySection >> Query.find [ Selector.tag "button" ] >> Query.has [ Selector.disabled True, Selector.text "Try again" ]
                            , Query.has [ Selector.text " You can try again in 17 s." ]
                            ]
            , test "a rate limit under a prerequisite turns its \"Try again\" off too" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Blocked { status = needsOrgJoin, notBefore = Just (millis 18000), joinCancelled = False }))
                        |> Expect.all
                            [ Query.has [ Selector.text "You need to join the course GitHub organization before a repository can be created for you." ]
                            , repositorySection >> Query.find [ Selector.tag "button" ] >> Query.has [ Selector.disabled True ]
                            ]
            , test "the button comes back once the hold is up" <|
                \_ ->
                    detail templateAssignment Nothing (Just (Failed { error = rateLimited, notBefore = Just (millis 1000) }))
                        |> repositorySection
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.hasNot [ Selector.disabled True ]
            , test "an expired session says to sign in again, with no retry" <|
                \_ ->
                    detail templateAssignment Nothing (Just (failed { code = "session_expired", retryable = False, httpStatus = 401, retryAfterSeconds = Nothing }))
                        |> Expect.all
                            [ Query.has [ Selector.text "Your session has expired. Reload the page and sign in again." ]
                            , repositorySection >> Query.hasNot [ Selector.tag "button" ]
                            ]
            , test "names the code of a conflict and offers no retry" <|
                \_ ->
                    detail templateAssignment Nothing (Just (failed { code = "submission_conflict", retryable = False, httpStatus = 409, retryAfterSeconds = Nothing }))
                        |> Expect.all
                            [ Query.has [ Selector.text "Please tell the teaching staff and mention the code \"submission_conflict\"." ]
                            , repositorySection >> Query.hasNot [ Selector.tag "button" ]
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


{-| The repository section of the page, apart from the answers form.
-}
repositorySection : Query.Single Msg -> Query.Single Msg
repositorySection =
    Query.find [ Selector.class "mb2" ]


{-| The detail page for one assignment, the student's submission to it if
any, and what is known about its repository. The clock reads one second
past the epoch.
-}
detail : Assignment -> Maybe AssignmentSubmission -> Maybe RepositoryProgress -> Query.Single Msg
detail =
    detailAs currentUser


detailAs : CurrentUser -> Assignment -> Maybe AssignmentSubmission -> Maybe RepositoryProgress -> Query.Single Msg
detailAs user =
    detailFor user Nothing


{-| The page with an answers request out (or failed) for the assignment.
-}
detailWithPending : Maybe (WebData (List AssignmentSubmission)) -> Assignment -> Maybe AssignmentSubmission -> Maybe RepositoryProgress -> Query.Single Msg
detailWithPending =
    detailFor currentUser


detailFor : CurrentUser -> Maybe (WebData (List AssignmentSubmission)) -> Assignment -> Maybe AssignmentSubmission -> Maybe RepositoryProgress -> Query.Single Msg
detailFor user pending =
    detailTyped user pending Dict.empty Dict.empty


{-| The page with what the student has typed: `inputs` under a submission
id, `drafts` under an assignment slug.
-}
detailTyped : CurrentUser -> Maybe (WebData (List AssignmentSubmission)) -> Dict.Dict ( Int, String ) String -> Dict.Dict String (Dict.Dict String String) -> Assignment -> Maybe AssignmentSubmission -> Maybe RepositoryProgress -> Query.Single Msg
detailTyped user pending inputs drafts assignment maybeSubmission maybeProgress =
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
        (pending |> Maybe.map (Dict.singleton assignment.slug) |> Maybe.withDefault Dict.empty)
        inputs
        drafts
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
        , fields = [ field "repository_url" True, field "notes" False ]
        , repository_template_provider = Just "github"
        , repository_template_full_name = Just "org/project-1-template"
        , repository_url_field_slug = Just "repository_url"
    }


field : String -> Bool -> AssignmentField
field slug isUrl =
    { slug = slug
    , assignment_slug = "project-1"
    , label = slug
    , help = ""
    , placeholder = ""
    , example = ""
    , pattern = ".*"
    , is_url = isUrl
    , is_multiline = False
    , display_order = 1
    , created_at = millis 0
    , updated_at = millis 0
    }


{-| An assignment that asks for nothing but the repository.
-}
repoOnlyAssignment : Assignment
repoOnlyAssignment =
    { templateAssignment | fields = [ field "repository_url" True ] }


submissionWith : AssignmentFieldSubmission -> AssignmentSubmission
submissionWith fieldSubmission =
    { submission | fields = [ fieldSubmission ] }


{-| The repository URL field, filled in.
-}
urlField : AssignmentFieldSubmission
urlField =
    { assignment_submission_id = submission.id
    , assignment_field_slug = "repository_url"
    , assignment_slug = "project-1"
    , body = repoUrl
    , submitter_user_id = currentUser.id
    , created_at = millis 0
    , updated_at = millis 0
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
