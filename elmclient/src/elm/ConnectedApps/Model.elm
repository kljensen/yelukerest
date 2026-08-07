module ConnectedApps.Model exposing
    ( ConnectedApp
    , ConnectedApps
    , connectedAppsDecoder
    )

import Json.Decode as Decode
import Json.Decode.Pipeline exposing (optional, required)


{-| One application the student has authorized to reach their course data.

`clientId` is the OAuth client id, which is the only thing the disconnect POST
actually needs; the rest is what makes the entry recognisable to a person.

-}
type alias ConnectedApp =
    { clientId : String
    , clientName : String
    , clientUri : Maybe String
    , scopes : List String
    , lastActivity : Maybe String
    }


{-| The listing plus the CSRF token that authorizes a disconnect.

The token is bound to the browser session and issued with the list, so a client
that fetched the list holds something it can act on once. Refetching the list
after a disconnect is how the next token arrives.

-}
type alias ConnectedApps =
    { apps : List ConnectedApp
    , csrfToken : String
    }


connectedAppDecoder : Decode.Decoder ConnectedApp
connectedAppDecoder =
    Decode.succeed ConnectedApp
        |> required "client_id" Decode.string
        |> required "client_name" Decode.string
        |> optional "client_uri" (Decode.nullable Decode.string) Nothing
        |> optional "scopes" (Decode.list Decode.string) []
        |> optional "last_activity" (Decode.nullable Decode.string) Nothing


connectedAppsDecoder : Decode.Decoder ConnectedApps
connectedAppsDecoder =
    Decode.succeed ConnectedApps
        -- A student with nothing connected gets no key at all rather than an
        -- empty list, so this tolerates its absence.
        |> optional "connected_apps" (Decode.list connectedAppDecoder) []
        |> required "csrf_token" Decode.string
