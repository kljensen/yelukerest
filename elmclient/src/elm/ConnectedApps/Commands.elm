module ConnectedApps.Commands exposing
    ( connectedAppsUrl
    , disconnectApp
    , fetchConnectedApps
    )

import ConnectedApps.Model exposing (ConnectedApps, connectedAppsDecoder)
import Http
import Msgs exposing (Msg)
import RemoteData
import Url.Builder


{-| These requests ride the browser session cookie, not the course JWT: the
endpoint is authapp's, and an application must never be able to disconnect
another application on the user's behalf. That is also why nothing here sets an
Authorization header.
-}
connectedAppsUrl : String
connectedAppsUrl =
    "/auth/connected-apps"


fetchConnectedApps : Cmd Msg
fetchConnectedApps =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Accept" "application/json" ]
        , url = connectedAppsUrl
        , body = Http.emptyBody
        , expect =
            Http.expectJson
                (RemoteData.fromResult >> Msgs.OnFetchConnectedApps)
                connectedAppsDecoder
        , timeout = Nothing
        , tracker = Nothing
        }


{-| Posts the disconnect exactly as the JS-free page's form does —
form-encoded, with the CSRF token that came back with the listing. The reply is
only checked for success or failure; the fresh list is fetched afterwards, so
the view never has to guess what the server now believes.
-}
disconnectApp : String -> String -> Cmd Msg
disconnectApp csrfToken clientId =
    Http.request
        { method = "POST"
        , headers = [ Http.header "Accept" "application/json" ]
        , url = connectedAppsUrl
        , body =
            Http.stringBody
                "application/x-www-form-urlencoded"
                (formEncode [ ( "csrf_token", csrfToken ), ( "client_id", clientId ) ])
        , expect = Http.expectWhatever (Msgs.OnDisconnectApp clientId)
        , timeout = Nothing
        , tracker = Nothing
        }


formEncode : List ( String, String ) -> String
formEncode pairs =
    pairs
        |> List.map (\( key, value ) -> Url.Builder.string key value)
        |> Url.Builder.toQuery
        -- toQuery leads with "?", which a request body must not carry.
        |> String.dropLeft 1
