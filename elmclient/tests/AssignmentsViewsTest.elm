module AssignmentsViewsTest exposing (tests)

import Assignments.Model exposing (Assignment, AssignmentSubmission)
import Assignments.Views
import Auth.Model exposing (CurrentUser)
import Dict
import Expect
import Html.Attributes as Attrs
import Http
import Models exposing (TimeZone)
import Msgs
import RemoteData
import Test exposing (Test, describe, test)
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
        , test "the form offers Submit when no save is pending" <|
            \_ ->
                formWithSave Nothing
                    |> Query.find [ Selector.tag "button" ]
                    |> Query.has [ Selector.text "Submit" ]
        , test "the Submit button is disabled while a save is in flight" <|
            \_ ->
                formWithSave (Just RemoteData.Loading)
                    |> Query.find [ Selector.tag "button" ]
                    |> Query.has [ Selector.text "Saving...", Selector.disabled True ]
        , test "a save rejected for an expired login says so and links to login" <|
            \_ ->
                formWithSave (Just (RemoteData.Failure (Http.BadStatus 401)))
                    |> Expect.all
                        [ Query.has [ Selector.text "Not saved: your login has expired." ]
                        , Query.find [ Selector.tag "a", Selector.attribute (Attrs.href "/auth/login") ]
                            >> Query.has [ Selector.text "Log in again" ]
                        ]
        , test "a save rejected for another reason shows the status code" <|
            \_ ->
                formWithSave (Just (RemoteData.Failure (Http.BadStatus 400)))
                    |> Query.has [ Selector.text "(HTTP 400)" ]
        , test "a network failure is reported as not saved" <|
            \_ ->
                formWithSave (Just (RemoteData.Failure Http.NetworkError))
                    |> Query.has [ Selector.text "Not saved: could not reach the server." ]
        , test "a successful save says so and shows no error" <|
            \_ ->
                formWithSave (Just (RemoteData.Success ()))
                    |> Expect.all
                        [ Query.has [ Selector.text "Saved." ]
                        , Query.hasNot [ Selector.text "Not saved" ]
                        ]
        , test "nothing is reported before the first save" <|
            \_ ->
                formWithSave Nothing
                    |> Expect.all
                        [ Query.hasNot [ Selector.text "Saved." ]
                        , Query.hasNot [ Selector.text "Not saved" ]
                        ]
        ]


{-| The detail page for an open assignment the student has already begun, so it
renders the submission form, with the given state for its pending save.
-}
formWithSave : Maybe (RemoteData.WebData ()) -> Query.Single Msgs.Msg
formWithSave maybePendingSave =
    Assignments.Views.detailView
        (RemoteData.Success currentUser)
        (Just (millis 1000))
        timeZone
        (RemoteData.Success [ baseAssignment ])
        (RemoteData.Success [ submission ])
        (RemoteData.Success [])
        Dict.empty
        (case maybePendingSave of
            Just pending ->
                Dict.singleton baseAssignment.slug pending

            Nothing ->
                Dict.empty
        )
        baseAssignment.slug
        Nothing
        |> Query.fromHtml


submission : AssignmentSubmission
submission =
    { id = 7
    , assignment_slug = baseAssignment.slug
    , is_team = False
    , user_id = Just currentUser.id
    , team_nickname = Nothing
    , submitter_user_id = currentUser.id
    , created_at = millis 500
    , updated_at = millis 500
    , fields = []
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
