module RoutingTest exposing (tests)

import Assignments.Model exposing (GithubJoinResult(..))
import Expect
import Models exposing (Route(..))
import Msgs exposing (BrowserLocation(..))
import Routing exposing (parseLocation)
import Test exposing (Test, describe, test)
import Url


{-| The startup path Main.init takes: Browser.application hands it a Url, not
a string. `Main.init` itself cannot be called from a test -- it needs a
Browser.Navigation.Key, which only a running program can produce -- so this
covers the part of it that does the work.
-}
urlLocation : String -> BrowserLocation
urlLocation href =
    case Url.fromString href of
        Just url ->
            UrlLocation url

        Nothing ->
            StringLocation href


tests : Test
tests =
    describe "Routing.parseLocation"
        [ test "parses root as index" <|
            \_ ->
                parseLocation (StringLocation "https://example.test/")
                    |> Expect.equal IndexRoute
        , test "parses hash routes used by the Elm client" <|
            \_ ->
                parseLocation (StringLocation "https://example.test/#assignments/homework-1/grade")
                    |> Expect.equal (AssignmentGradeDetailRoute "homework-1")
        , test "parses the connected-applications route" <|
            \_ ->
                parseLocation (StringLocation "https://example.test/#connected-apps")
                    |> Expect.equal ConnectedAppsRoute
        , test "parses the data-grants route" <|
            \_ ->
                parseLocation (StringLocation "https://example.test/#data-grants")
                    |> Expect.equal DataGrantsRoute
        , test "parses the MCP instructions route" <|
            \_ ->
                parseLocation (StringLocation "https://example.test/#mcp")
                    |> Expect.equal McpRoute
        , test "routes the Url that Browser.application hands Main.init" <|
            \_ ->
                urlLocation "https://www.656.mba/#/mcp"
                    |> parseLocation
                    |> Expect.equal McpRoute
        , test "routes a deep link on startup, not just the index" <|
            \_ ->
                urlLocation "https://www.656.mba/#/assignments/homework-1"
                    |> parseLocation
                    |> Expect.equal (AssignmentDetailRoute "homework-1")
        , describe "the return from the GitHub join (issue #399)"
            [ test "ok" <|
                \_ ->
                    parseLocation (StringLocation "https://example.test/#/assignments/project-1?github_join=ok")
                        |> Expect.equal (AssignmentJoinReturnRoute "project-1" JoinOk)
            , test "denied" <|
                \_ ->
                    parseLocation (StringLocation "https://example.test/#/assignments/project-1?github_join=denied")
                        |> Expect.equal (AssignmentJoinReturnRoute "project-1" JoinDenied)
            , test "an error, with its code" <|
                \_ ->
                    parseLocation (StringLocation "https://example.test/#/assignments/project-1?github_join=error:github_identity_taken")
                        |> Expect.equal (AssignmentJoinReturnRoute "project-1" (JoinError "github_identity_taken"))
            , test "a marker nobody sends is ignored" <|
                \_ ->
                    parseLocation (StringLocation "https://example.test/#/assignments/project-1?github_join=maybe")
                        |> Expect.equal (AssignmentDetailRoute "project-1")
            , test "an unrelated query leaves the plain route" <|
                \_ ->
                    parseLocation (StringLocation "https://example.test/#/assignments/project-1?utm=x")
                        |> Expect.equal (AssignmentDetailRoute "project-1")
            , test "the marker is not part of the slug" <|
                \_ ->
                    parseLocation (StringLocation "https://example.test/#assignments/project-1?github_join=ok")
                        |> Expect.equal (AssignmentJoinReturnRoute "project-1" JoinOk)
            ]
        , test "online quiz-taking route is no longer available" <|
            \_ ->
                parseLocation (StringLocation "https://example.test/#quiz-submissions/123")
                    |> Expect.equal NotFoundRoute
        , test "returns NotFoundRoute for non-hash paths" <|
            \_ ->
                parseLocation (StringLocation "https://example.test/assignments/homework-1")
                    |> Expect.equal NotFoundRoute
        , test "returns NotFoundRoute for invalid URLs" <|
            \_ ->
                parseLocation (StringLocation "not a url")
                    |> Expect.equal NotFoundRoute
        ]
