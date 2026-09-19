module AssignmentsCommandsTest exposing (tests)

import Assignments.Commands exposing (repositoryResponse, repositoryUrl)
import Assignments.Model exposing (RepositoryState(..))
import Dict
import Expect
import Http
import Test exposing (Test, describe, test)


{-| The HTTP contract of `/auth/assignments/{slug}/repository`, as the
client reads it: a status body on 2xx, an error body with a code otherwise,
and `Retry-After` on top.
-}
tests : Test
tests =
    describe "Assignments.Commands.repositoryResponse"
        [ test "the URL is authapp's, keyed by slug" <|
            \_ ->
                repositoryUrl "project-1"
                    |> Expect.equal "/auth/assignments/project-1/repository"
        , describe "a status body"
            [ test "ready on 200, with the repository URL" <|
                \_ ->
                    repositoryResponse (good 200 """{"state":"ready","repo_url":"https://github.com/org/repo","join_url":null}""")
                        |> Expect.equal (Ok { state = Ready, repoUrl = Just "https://github.com/org/repo", joinUrl = Nothing })
            , test "copying on 202" <|
                \_ ->
                    repositoryResponse (good 202 """{"state":"copying","repo_url":"https://github.com/org/repo","join_url":null}""")
                        |> Expect.equal (Ok { state = Copying, repoUrl = Just "https://github.com/org/repo", joinUrl = Nothing })
            , test "needs_org_join carries the join URL" <|
                \_ ->
                    repositoryResponse (good 200 """{"state":"needs_org_join","repo_url":null,"join_url":"https://github.com/orgs/x/invitation"}""")
                        |> Expect.equal (Ok { state = NeedsOrgJoin, repoUrl = Nothing, joinUrl = Just "https://github.com/orgs/x/invitation" })
            , test "needs_github_link" <|
                \_ ->
                    repositoryResponse (good 200 """{"state":"needs_github_link","repo_url":null,"join_url":null}""")
                        |> Expect.equal (Ok { state = NeedsGithubLink, repoUrl = Nothing, joinUrl = Nothing })
            , test "a state this client does not know is a retryable failure, not a crash" <|
                \_ ->
                    repositoryResponse (good 200 """{"state":"archived","repo_url":null,"join_url":null}""")
                        |> Expect.equal (Err { code = "unexpected_response", retryable = True, httpStatus = 200, retryAfterSeconds = Nothing })
            ]
        , describe "an error body"
            [ test "carries the server's code and whether to retry" <|
                \_ ->
                    repositoryResponse (bad 409 Dict.empty """{"error":{"code":"name_taken","retryable":false}}""")
                        |> Expect.equal (Err { code = "name_taken", retryable = False, httpStatus = 409, retryAfterSeconds = Nothing })
            , test "404 before any create is repository_not_started" <|
                \_ ->
                    repositoryResponse (bad 404 Dict.empty """{"error":{"code":"repository_not_started","retryable":false}}""")
                        |> Expect.equal (Err { code = "repository_not_started", retryable = False, httpStatus = 404, retryAfterSeconds = Nothing })
            , test "reads Retry-After in seconds" <|
                \_ ->
                    repositoryResponse (bad 429 (Dict.fromList [ ( "retry-after", "17" ) ]) """{"error":{"code":"rate_limited","retryable":true}}""")
                        |> Expect.equal (Err { code = "rate_limited", retryable = True, httpStatus = 429, retryAfterSeconds = Just 17 })
            , test "reads Retry-After whatever its case" <|
                \_ ->
                    repositoryResponse (bad 502 (Dict.fromList [ ( "Retry-After", "5" ) ]) """{"error":{"code":"github_unavailable","retryable":true}}""")
                        |> Expect.equal (Err { code = "github_unavailable", retryable = True, httpStatus = 502, retryAfterSeconds = Just 5 })
            , test "a 429 without a body is still a rate limit" <|
                \_ ->
                    repositoryResponse (bad 429 (Dict.fromList [ ( "retry-after", "30" ) ]) "Too Many Requests")
                        |> Expect.equal (Err { code = "rate_limited", retryable = True, httpStatus = 429, retryAfterSeconds = Just 30 })
            , test "a 429 without a body or a Retry-After asks for 30 seconds" <|
                \_ ->
                    repositoryResponse (bad 429 Dict.empty "")
                        |> Expect.equal (Err { code = "rate_limited", retryable = True, httpStatus = 429, retryAfterSeconds = Just 30 })
            , test "a 5xx without a body is a generic retryable failure" <|
                \_ ->
                    repositoryResponse (bad 503 Dict.empty "<html>Service Unavailable</html>")
                        |> Expect.equal (Err { code = "http_503", retryable = True, httpStatus = 503, retryAfterSeconds = Nothing })
            , test "a 408 without a body is retryable" <|
                \_ ->
                    repositoryResponse (bad 408 Dict.empty "")
                        |> Expect.equal (Err { code = "http_408", retryable = True, httpStatus = 408, retryAfterSeconds = Nothing })
            , test "a 403 without a body is not" <|
                \_ ->
                    repositoryResponse (bad 403 Dict.empty "<html>Forbidden</html>")
                        |> Expect.equal (Err { code = "http_403", retryable = False, httpStatus = 403, retryAfterSeconds = Nothing })
            , test "nor is a 404 without a body" <|
                \_ ->
                    repositoryResponse (bad 404 Dict.empty "<html>Not Found</html>")
                        |> Expect.equal (Err { code = "http_404", retryable = False, httpStatus = 404, retryAfterSeconds = Nothing })
            , test "a 401 without a body means the session is gone" <|
                \_ ->
                    repositoryResponse (bad 401 Dict.empty "<html>Unauthorized</html>")
                        |> Expect.equal (Err { code = "session_expired", retryable = False, httpStatus = 401, retryAfterSeconds = Nothing })
            , test "so does a 401 with one, whatever it says" <|
                \_ ->
                    repositoryResponse (bad 401 Dict.empty """{"error":{"code":"not_signed_in","retryable":true}}""")
                        |> Expect.equal (Err { code = "session_expired", retryable = False, httpStatus = 401, retryAfterSeconds = Nothing })
            ]
        , describe "no answer"
            [ test "a timeout is retryable" <|
                \_ ->
                    repositoryResponse Http.Timeout_
                        |> Expect.equal (Err { code = "timeout", retryable = True, httpStatus = 0, retryAfterSeconds = Nothing })
            , test "a lost connection is retryable" <|
                \_ ->
                    repositoryResponse Http.NetworkError_
                        |> Expect.equal (Err { code = "network_error", retryable = True, httpStatus = 0, retryAfterSeconds = Nothing })
            ]
        ]


good : Int -> String -> Http.Response String
good status body =
    Http.GoodStatus_ (metadata status Dict.empty) body


bad : Int -> Dict.Dict String String -> String -> Http.Response String
bad status headers body =
    Http.BadStatus_ (metadata status headers) body


metadata : Int -> Dict.Dict String String -> Http.Metadata
metadata status headers =
    { url = repositoryUrl "project-1"
    , statusCode = status
    , statusText = ""
    , headers = headers
    }
