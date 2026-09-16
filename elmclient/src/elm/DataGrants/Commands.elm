module DataGrants.Commands exposing
    ( createDataGrant
    , fetchDataGrants
    , revokeDataGrant
    )

{-| Same shape as ApiTokens.Commands: PostgREST with the course JWT, and the
database decides who may do what (faculty only, here). The difference is that
a grant is not the caller's own credential -- it is a permission handed to an
app -- so the listing is every grant the course has, not "yours".
-}

import Auth.Commands exposing (fetchForCurrentUser, sendRequestWithJWT)
import Auth.Model exposing (CurrentUser)
import DataGrants.Model exposing (CreatedGrant, GrantDraft, apiGrantsDecoder, createGrantBody, createdGrantDecoder)
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Msgs exposing (Msg)


fetchDataGrantsUrl : String
fetchDataGrantsUrl =
    "/rest/api_grants?order=created_at.desc"


fetchDataGrants : CurrentUser -> Cmd Msg
fetchDataGrants currentUser =
    fetchForCurrentUser currentUser fetchDataGrantsUrl apiGrantsDecoder Msgs.OnFetchDataGrants


{-| Create a grant. The response carries the credential and is the only time
it exists outside the database, so the caller must show it immediately.

Unlike a personal token, the request can be refused for reasons the form
cannot check itself -- an expiry past the 180-day cap, an assignment named
twice -- so the server's own message is carried back rather than a bare
status code.

-}
createDataGrant : CurrentUser -> GrantDraft -> Cmd Msg
createDataGrant currentUser draft =
    Http.request
        { method = "POST"
        , headers =
            [ Http.header "Authorization" ("Bearer " ++ currentUser.jwt)

            -- A single object rather than a one-element array.
            , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]
        , url = "/rest/rpc/create_api_grant"
        , body = Http.jsonBody (createGrantBody draft)
        , expect = Http.expectStringResponse Msgs.OnCreateDataGrant createdGrantResult
        , timeout = Nothing
        , tracker = Nothing
        }


createdGrantResult : Http.Response String -> Result String CreatedGrant
createdGrantResult response =
    case response of
        Http.GoodStatus_ _ body ->
            Decode.decodeString createdGrantDecoder body
                |> Result.mapError (\_ -> "The grant may have been created, but the reply could not be read. Check the list below.")

        Http.BadStatus_ { statusCode } body ->
            Err (postgrestMessage statusCode body)

        Http.Timeout_ ->
            Err "The request timed out."

        Http.NetworkError_ ->
            Err "The request did not reach the server."

        Http.BadUrl_ url ->
            Err ("Bad URL: " ++ url)


{-| PostgREST reports a raised exception as `{"message": ...}`, which for this
RPC is the plain-English reason `data.create_api_grant_rows` refused.
-}
postgrestMessage : Int -> String -> String
postgrestMessage statusCode body =
    Decode.decodeString (Decode.field "message" Decode.string) body
        |> Result.withDefault ("The server refused the request (HTTP " ++ String.fromInt statusCode ++ ").")


{-| Revoking is one-way and a second call is a no-op on the server, so the
UI treats it as idempotent: it refetches and shows whatever is recorded.
-}
revokeDataGrant : CurrentUser -> Int -> Cmd Msg
revokeDataGrant currentUser grantId =
    sendRequestWithJWT
        currentUser.jwt
        "/rest/rpc/revoke_api_grant"
        "POST"
        (Http.jsonBody (Encode.object [ ( "p_id", Encode.int grantId ) ]))
        (Decode.succeed ())
        (Msgs.OnRevokeDataGrant grantId)
