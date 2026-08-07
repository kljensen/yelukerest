module ConnectedAppsModelTest exposing (tests)

import ConnectedApps.Model exposing (connectedAppsDecoder)
import Expect
import Json.Decode as Decode
import Test exposing (Test, describe, test)


{-| These fixtures are the shape authapp actually returns; the end-to-end suite
asserts the server keeps producing it (tests/oauth/connected-apps.js), so the
two halves of the contract are pinned from both sides.
-}
tests : Test
tests =
    describe "ConnectedApps.Model.connectedAppsDecoder"
        [ test "decodes a listing with one application" <|
            \_ ->
                """
                { "connected_apps":
                    [ { "client_id": "abc"
                      , "client_name": "Claude"
                      , "scopes": ["course:read", "grades:read"]
                      , "last_activity": "2026-08-07T18:21:55Z"
                      }
                    ]
                , "csrf_token": "deadbeef"
                }
                """
                    |> Decode.decodeString connectedAppsDecoder
                    |> Result.map (\payload -> ( List.length payload.apps, payload.csrfToken ))
                    |> Expect.equal (Ok ( 1, "deadbeef" ))
        , test "tolerates a missing client_uri, which the server omits when empty" <|
            \_ ->
                """
                { "connected_apps": [ { "client_id": "abc", "client_name": "Claude", "scopes": [] } ]
                , "csrf_token": "t"
                }
                """
                    |> Decode.decodeString connectedAppsDecoder
                    |> Result.map (\payload -> List.map .clientUri payload.apps)
                    |> Expect.equal (Ok [ Nothing ])
        , test "treats an absent connected_apps key as nothing connected" <|
            \_ ->
                """{ "csrf_token": "t" }"""
                    |> Decode.decodeString connectedAppsDecoder
                    |> Result.map (\payload -> List.length payload.apps)
                    |> Expect.equal (Ok 0)
        , test "fails without a csrf token, since a disconnect could not be sent" <|
            \_ ->
                """{ "connected_apps": [] }"""
                    |> Decode.decodeString connectedAppsDecoder
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]
