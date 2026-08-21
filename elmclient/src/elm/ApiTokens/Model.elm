module ApiTokens.Model exposing
    ( ApiToken
    , CreatedToken
    , allScopes
    , apiTokensDecoder
    , createdTokenDecoder
    , defaultScopes
    , scopeDescription
    , writeScope
    )

import Json.Decode as Decode
import Json.Decode.Pipeline exposing (optional, required)


{-| One personal access token as the API reports it.

There is no secret here on purpose. `api.user_api_tokens` does not expose the
token or its hash, so a listing can never hand back something usable — the
secret is shown exactly once, at creation, and after that only its prefix
identifies it.

`lastUsed` earns its place in the model rather than being computed away: for a
credential that lives four months it is the only evidence that one the student
forgot about is still being used.

-}
type alias ApiToken =
    { id : Int
    , tokenPrefix : String
    , name : String
    , scopes : List String
    , createdAt : String
    , expiresAt : String
    , lastUsedAt : Maybe String
    , revokedAt : Maybe String
    , isActive : Bool
    }


{-| The one-time response from creating a token. `token` is the full secret and
is never obtainable again; the view must say so plainly.
-}
type alias CreatedToken =
    { id : Int
    , token : String
    , tokenPrefix : String
    , name : String
    , scopes : List String
    , expiresAt : String
    }


{-| The scope vocabulary, shared with MCP rather than invented here.
-}
allScopes : List String
allScopes =
    [ "course:read", "grades:read", "submissions:read", writeScope ]


{-| Read-only by default. A token can only submit work if the student ticks the
write scope when creating it, which is the same choice the MCP consent page
presents with the box unchecked.
-}
defaultScopes : List String
defaultScopes =
    [ "course:read", "grades:read", "submissions:read" ]


writeScope : String
writeScope =
    "submissions:write"


scopeDescription : String -> String
scopeDescription scope =
    case scope of
        "course:read" ->
            "Read meetings, assignments and quizzes"

        "grades:read" ->
            "Read your own grades"

        "submissions:read" ->
            "Read your own submissions"

        "submissions:write" ->
            "Submit and change your work"

        other ->
            other


apiTokenDecoder : Decode.Decoder ApiToken
apiTokenDecoder =
    Decode.succeed ApiToken
        |> required "id" Decode.int
        |> required "token_prefix" Decode.string
        |> required "name" Decode.string
        |> optional "scopes" (Decode.list Decode.string) []
        |> required "created_at" Decode.string
        |> required "expires_at" Decode.string
        |> optional "last_used_at" (Decode.nullable Decode.string) Nothing
        |> optional "revoked_at" (Decode.nullable Decode.string) Nothing
        |> optional "is_active" Decode.bool False


apiTokensDecoder : Decode.Decoder (List ApiToken)
apiTokensDecoder =
    Decode.list apiTokenDecoder


createdTokenDecoder : Decode.Decoder CreatedToken
createdTokenDecoder =
    Decode.succeed CreatedToken
        |> required "id" Decode.int
        |> required "token" Decode.string
        |> required "token_prefix" Decode.string
        |> required "name" Decode.string
        |> optional "scopes" (Decode.list Decode.string) []
        |> required "expires_at" Decode.string
