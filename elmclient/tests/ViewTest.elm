module ViewTest exposing (tests)

import Auth.Model exposing (CurrentUser)
import Html.Attributes as Attrs
import Http
import Models exposing (UIElements)
import RemoteData
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import View


{-| The repositories page is served by authapp to students only, so the front
page links to it exactly when it works: for a signed-in student and nobody
else.
-}
tests : Test
tests =
    describe "View.indexView"
        [ test "links a signed-in student to the repositories page" <|
            \_ ->
                View.indexView (RemoteData.Success student) uiElements
                    |> Query.fromHtml
                    |> Query.find [ Selector.attribute (Attrs.href "/auth/repositories") ]
                    |> Query.has [ Selector.text "Repositories" ]
        , test "shows no repositories link when signed out" <|
            \_ ->
                View.indexView (RemoteData.Failure (Http.BadStatus 401)) uiElements
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.attribute (Attrs.href "/auth/repositories") ]
        , test "shows no repositories link to faculty" <|
            \_ ->
                View.indexView (RemoteData.Success { student | role = "faculty" }) uiElements
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.attribute (Attrs.href "/auth/repositories") ]
        ]


student : CurrentUser
student =
    { id = 42
    , netid = "abc123"
    , jwt = "jwt"
    , role = "student"
    , nickname = "student"
    , team_nickname = Nothing
    }


uiElements : UIElements
uiElements =
    { courseTitle = "Course"
    , piazzaURL = Nothing
    , aboutURL = "/about"
    , canvasURL = "/canvas"
    , slackURL = Nothing
    , mcpEndpoint = "https://example.test/mcp"
    }
