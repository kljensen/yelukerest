module McpViewsTest exposing (tests)

import Expect
import Mcp.Views exposing (connectionLabel)
import Test exposing (Test, describe, test)


tests : Test
tests =
    describe "Mcp.Views.connectionLabel"
        [ test "lowercases the course title and joins its words with dashes" <|
            \_ ->
                connectionLabel "MGT 802: Software Development"
                    |> Expect.equal "mgt-802-software-development"
        , test "keeps a title that is already one word" <|
            \_ ->
                connectionLabel "MGT101"
                    |> Expect.equal "mgt101"
        , test "falls back to a generic label when the title is empty" <|
            \_ ->
                connectionLabel ""
                    |> Expect.equal "course"
        ]
