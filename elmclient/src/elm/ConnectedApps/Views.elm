module ConnectedApps.Views exposing (listView)

import ConnectedApps.Model exposing (ConnectedApp, ConnectedApps)
import Html exposing (Html, a, button, div, h1, h2, li, p, span, text, ul)
import Html.Attributes exposing (class, disabled, href)
import Html.Events exposing (onClick)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Set exposing (Set)


{-| The connected-applications page.

`pending` holds the client ids whose disconnect is in flight, so the button
that was pressed says so and cannot be pressed twice.

-}
listView : WebData ConnectedApps -> Set String -> Html Msg
listView connectedApps pending =
    div [ class "connected-apps" ]
        [ h1 [] [ text "Connected applications" ]
        , case connectedApps of
            RemoteData.NotAsked ->
                p [] [ text "Loading…" ]

            RemoteData.Loading ->
                p [] [ text "Loading…" ]

            RemoteData.Failure _ ->
                p [ class "error" ]
                    [ text "Could not read your connected applications. "
                    , a [ href "/auth/connected-apps" ]
                        [ text "Open the standalone page" ]
                    , text " if this keeps happening."
                    ]

            RemoteData.Success payload ->
                if List.isEmpty payload.apps then
                    p [] [ text "No applications are connected to your account." ]

                else
                    div []
                        [ p []
                            [ text
                                ("These applications can reach your course data using your "
                                    ++ "account. Disconnect anything you do not recognise or "
                                    ++ "no longer use."
                                )
                            ]
                        , ul [ class "apps" ]
                            (List.map (appView payload.csrfToken pending) payload.apps)
                        , p [ class "fine-print" ]
                            [ text
                                ("Disconnecting stops an application from getting new access "
                                    ++ "straight away. Access it already holds stops working "
                                    ++ "within a few minutes."
                                )
                            ]
                        ]
        ]


appView : String -> Set String -> ConnectedApp -> Html Msg
appView csrfToken pending app =
    let
        isPending =
            Set.member app.clientId pending
    in
    li [ class "app" ]
        [ h2 [ class "app-name" ] [ text app.clientName ]
        , case app.clientUri of
            Just uri ->
                div [ class "app-uri" ] [ a [ href uri ] [ text uri ] ]

            Nothing ->
                text ""
        , div [ class "app-scopes" ]
            [ text "Can: "
            , span [] [ text (scopeSummary app.scopes) ]
            ]
        , case app.lastActivity of
            Just when ->
                div [ class "app-when" ] [ text ("Last approved " ++ when) ]

            Nothing ->
                text ""
        , button
            [ class "disconnect"
            , disabled isPending
            , onClick (Msgs.DisconnectApp csrfToken app.clientId)
            ]
            [ text
                (if isPending then
                    "Disconnecting…"

                 else
                    "Disconnect"
                )
            ]
        ]


{-| Scopes as the student sees them. The raw names are shown rather than
prettified: they are what the consent screen said, and matching the two is more
useful here than nicer words.
-}
scopeSummary : List String -> String
scopeSummary scopes =
    case scopes of
        [] ->
            "nothing"

        _ ->
            String.join ", " scopes
