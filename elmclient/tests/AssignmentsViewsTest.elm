module AssignmentsViewsTest exposing (tests)

import Assignments.Model exposing (Assignment, AssignmentField, AssignmentFieldSubmission, AssignmentSubmission, MyRepository)
import Assignments.Updates exposing (onSubmitAssignmentFieldSubmissionsResponse)
import Assignments.Views
import Auth.Model exposing (CurrentUser)
import Dict
import Html.Attributes as Attrs
import Models exposing (TimeZone)
import Msgs
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
                    RemoteData.NotAsked
                    baseAssignment.slug
                    Nothing
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "10 points" ]

        -- The inputs are bound to the model, so what the model keeps after a
        -- save is what the student sees. Clearing it blanked the form.
        , test "the form still shows the typed value after a successful save" <|
            \_ ->
                let
                    ( saved, _ ) =
                        onSubmitAssignmentFieldSubmissionsResponse baseAssignment.slug
                            (RemoteData.Success [])
                            { pendingAssignmentFieldSubmissionRequests = Dict.empty
                            , assignmentFieldSubmissionInputs = Dict.singleton ( submission.id, urlField.slug ) repoUrl
                            }
                in
                formView saved.assignmentFieldSubmissionInputs RemoteData.NotAsked
                    |> Query.find [ Selector.tag "form" ]
                    |> Query.find [ Selector.tag "input", Selector.attribute (Attrs.name urlField.slug) ]
                    |> Query.has [ Selector.attribute (Attrs.value repoUrl) ]

        -- The one-click fill: a student who created a repository for this
        -- assignment is offered its URL beneath an empty URL field, and
        -- nothing more. Staff never fetch my_repositories, so for them the
        -- data is NotAsked and nothing renders, by construction.
        , describe "repository hint"
            [ test "offers the repository for an empty URL field the pattern accepts" <|
                \_ ->
                    formView Dict.empty (RemoteData.Success [ repository ])
                        |> Query.find [ Selector.class "repository-hint" ]
                        |> Query.has
                            [ Selector.text "Your repository for this assignment: "
                            , Selector.attribute (Attrs.href repoUrl)
                            , Selector.text "Use it"
                            ]
            , test "Use it sets the field's input to the URL" <|
                \_ ->
                    formView Dict.empty (RemoteData.Success [ repository ])
                        |> Query.find [ Selector.class "repository-hint" ]
                        |> Query.find [ Selector.tag "button" ]
                        |> Event.simulate Event.click
                        |> Event.expect (Msgs.OnUpdateAssignmentFieldSubmissionInput submission.id urlField.slug repoUrl)
            , test "Use it does not submit the form" <|
                \_ ->
                    formView Dict.empty (RemoteData.Success [ repository ])
                        |> Query.find [ Selector.class "repository-hint" ]
                        |> Query.find [ Selector.tag "button" ]
                        |> Query.has [ Selector.attribute (Attrs.type_ "button") ]
            , test "shows nothing once the student has typed in the field" <|
                \_ ->
                    formView (Dict.singleton ( submission.id, urlField.slug ) "x") (RemoteData.Success [ repository ])
                        |> Query.hasNot [ Selector.class "repository-hint" ]
            , test "shows nothing when the field already has a recorded body" <|
                \_ ->
                    detailWith { submission | fields = [ recordedField ] } Dict.empty (RemoteData.Success [ repository ])
                        |> Query.hasNot [ Selector.class "repository-hint" ]
            , test "shows nothing for a repository created for another assignment" <|
                \_ ->
                    formView Dict.empty (RemoteData.Success [ { repository | assignment_slug = Just "other" } ])
                        |> Query.hasNot [ Selector.class "repository-hint" ]
            , test "shows nothing without rows" <|
                \_ ->
                    formView Dict.empty (RemoteData.Success [])
                        |> Query.hasNot [ Selector.class "repository-hint" ]
            , test "shows nothing when repositories were never fetched, as for staff" <|
                \_ ->
                    detailWithUser { currentUser | role = "faculty" } urlField submission Dict.empty RemoteData.NotAsked
                        |> Query.hasNot [ Selector.class "repository-hint" ]
            ]
        ]


formView : Dict.Dict ( Int, String ) String -> WebData (List MyRepository) -> Query.Single Msgs.Msg
formView =
    detailWith submission


detailWith : AssignmentSubmission -> Dict.Dict ( Int, String ) String -> WebData (List MyRepository) -> Query.Single Msgs.Msg
detailWith =
    detailWithUser currentUser urlField


detailWithUser : CurrentUser -> AssignmentField -> AssignmentSubmission -> Dict.Dict ( Int, String ) String -> WebData (List MyRepository) -> Query.Single Msgs.Msg
detailWithUser user field sub inputs repositories =
    Assignments.Views.detailView
        (RemoteData.Success user)
        (Just (millis 1000))
        timeZone
        (RemoteData.Success [ { baseAssignment | fields = [ field ] } ])
        (RemoteData.Success [ sub ])
        (RemoteData.Success [])
        Dict.empty
        inputs
        repositories
        baseAssignment.slug
        Nothing
        |> Query.fromHtml


repoUrl : String
repoUrl =
    "https://github.com/org/starter-abc123"


repository : MyRepository
repository =
    { template_slug = "t"
    , label = "Starter"
    , assignment_slug = Just baseAssignment.slug
    , template_full_name = "org/starter"
    , repo_url = Just repoUrl
    , is_team = False
    , user_id = Just currentUser.id
    , team_nickname = Nothing
    , provider_full_name = "org/starter-abc123"
    , created_at = millis 0
    }


urlField : AssignmentField
urlField =
    { slug = "repo-url"
    , assignment_slug = baseAssignment.slug
    , label = "Repository URL"
    , help = ""
    , placeholder = ""
    , example = ""
    , pattern = "https://github\\.com/.*"
    , is_url = True
    , is_multiline = False
    , display_order = 1
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


recordedField : AssignmentFieldSubmission
recordedField =
    { assignment_submission_id = submission.id
    , assignment_field_slug = urlField.slug
    , assignment_slug = baseAssignment.slug
    , body = "https://github.com/org/typed-by-hand"
    , submitter_user_id = currentUser.id
    , created_at = millis 0
    , updated_at = millis 0
    }


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


millis : Int -> Time.Posix
millis =
    Time.millisToPosix
