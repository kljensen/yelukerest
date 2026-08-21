module ApiTokens.Commands exposing
    ( createApiToken
    , fetchApiTokens
    , revokeApiToken
    )

{-| These go to PostgREST with the course JWT, unlike ConnectedApps which rides
the browser session because its endpoint is authapp's.

That difference is the whole shape of the feature: creating, listing and
revoking a token are things a person does to their own rows, so row-level
security is the entire authorization story and no new HTTP surface is needed.
Only the exchange (POST /auth/token) lives in authapp, because the caller
presenting a token there has no session and no JWT yet.

-}

import ApiTokens.Model exposing (ApiToken, CreatedToken, apiTokensDecoder, createdTokenDecoder)
import Auth.Commands exposing (fetchForCurrentUser, sendRequestWithJWT)
import Auth.Model exposing (CurrentUser)
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Msgs exposing (Msg)
import RemoteData


fetchApiTokensUrl : String
fetchApiTokensUrl =
    -- Newest first: the one a student just made is the one they are looking
    -- for. Row-level security limits this to their own tokens.
    "/rest/user_api_tokens?order=created_at.desc"


fetchApiTokens : CurrentUser -> Cmd Msg
fetchApiTokens currentUser =
    fetchForCurrentUser currentUser fetchApiTokensUrl apiTokensDecoder Msgs.OnFetchApiTokens


{-| Create a token. The response carries the secret and is the only time it
exists outside the database, so the caller must show it immediately.
-}
createApiToken : CurrentUser -> String -> List String -> Cmd Msg
createApiToken currentUser name scopes =
    let
        body =
            Http.jsonBody
                (Encode.object
                    [ ( "p_name", Encode.string name )
                    , ( "p_scopes", Encode.list Encode.string scopes )
                    ]
                )
    in
    Http.request
        { method = "POST"
        , headers =
            [ Http.header "Authorization" ("Bearer " ++ currentUser.jwt)

            -- Ask PostgREST for a single object rather than a one-element
            -- array, so the decoder does not have to unwrap it.
            , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]
        , url = "/rest/rpc/create_user_api_token"
        , body = body
        , expect =
            Http.expectJson
                (RemoteData.fromResult >> Msgs.OnCreateApiToken)
                createdTokenDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Revoking is a dedicated RPC rather than a PATCH. The view exposes `scopes`
and `expires_at`, so granting UPDATE on it would let a holder widen their own
token or push its expiry out; this can only ever set revoked_at.
-}
revokeApiToken : CurrentUser -> Int -> Cmd Msg
revokeApiToken currentUser tokenId =
    sendRequestWithJWT
        currentUser.jwt
        "/rest/rpc/revoke_user_api_token"
        "POST"
        (Http.jsonBody (Encode.object [ ( "p_id", Encode.int tokenId ) ]))
        (Decode.succeed ())
        (Msgs.OnRevokeApiToken tokenId)
