module AssignmentsViewsTest exposing (tests)

import Assignments.Model exposing (Assignment)
import Assignments.Views
import Auth.Model exposing (CurrentUser)
import Dict
import Models exposing (TimeZone)
import RemoteData
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Time exposing (ZoneName(..))


tests : Test
tests =
    describe "Assignments.Views"
        [ test "listView shows assignment points possible" <|
            \_ ->
                Assignments.Views.listView timeZone (RemoteData.Success [ baseAssignment ])
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Points possible: 10 points" ]
        , test "detailView shows assignment points possible" <|
            \_ ->
                Assignments.Views.detailView
                    (RemoteData.Success currentUser)
                    (Just (millis 1000))
                    timeZone
                    (RemoteData.Success [ baseAssignment ])
                    (RemoteData.Success [])
                    (RemoteData.Success [])
                    Dict.empty
                    baseAssignment.slug
                    Nothing
                    |> Query.fromHtml
                    |> Query.has [ Selector.text "Points possible: 10 points" ]
        ]


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
