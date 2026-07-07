module RoutingTest exposing (tests)

import Expect
import Models exposing (Route(..))
import Msgs exposing (BrowserLocation(..))
import Routing exposing (parseLocation)
import Test exposing (Test, describe, test)


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
