module McpEndpointTest exposing (tests)

import Expect
import Models exposing (mcpEndpoint)
import Test exposing (Test, describe, test)
import Url


endpointFor : String -> String
endpointFor href =
    case Url.fromString href of
        Just url ->
            mcpEndpoint url

        Nothing ->
            "could not parse " ++ href


tests : Test
tests =
    describe "Models.mcpEndpoint"
        [ test "uses the origin, not the page the student is on" <|
            \_ ->
                endpointFor "https://www.656.mba/#/mcp"
                    |> Expect.equal "https://www.656.mba/mcp"
        , -- What the client actually sees: a browser location for an
          -- ordinary https site carries no port, so `port_` is Nothing and
          -- nothing is printed. This does not exercise an explicit `:443`,
          -- which the client has no way to be handed and which mcpEndpoint
          -- would print verbatim.
          test "prints no port when the browser URL carries none" <|
            \_ ->
                endpointFor "https://localhost/#/assignments"
                    |> Expect.equal "https://localhost/mcp"
        , test "keeps a non-default port" <|
            \_ ->
                endpointFor "https://localhost:8443/#/mcp"
                    |> Expect.equal "https://localhost:8443/mcp"
        , test "keeps the scheme it was served over" <|
            \_ ->
                endpointFor "http://localhost:8080/"
                    |> Expect.equal "http://localhost:8080/mcp"
        ]
