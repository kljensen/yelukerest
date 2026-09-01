module ApiTokens.Views exposing (listView)

import ApiTokens.Model exposing (ApiToken, CreatedToken, allScopes, scopeDescription, writeScope)
import Html exposing (Html, button, code, div, fieldset, h1, h2, input, label, legend, li, p, span, table, tbody, td, text, th, thead, tr, ul)
import Html.Attributes exposing (attribute, checked, class, disabled, for, id, placeholder, type_, value)
import Html.Events exposing (onCheck, onClick, onInput)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Set exposing (Set)


listView : WebData (List ApiToken) -> Maybe CreatedToken -> String -> Set String -> Set Int -> Html Msg
listView tokens justCreated draftName draftScopes pendingRevokes =
    div [ class "api-tokens" ]
        [ h1 [] [ text "API tokens" ]
        , introduction
        , justCreatedView justCreated
        , createFormView draftName draftScopes
        , h2 [] [ text "Your tokens" ]
        , tokenTableView tokens pendingRevokes
        ]


{-| No link to the documentation, deliberately: it lives in a private
repository, so every student following it would land on a 404 while being told
it was their own sign-in that was wrong. The one thing they need is short
enough to say here.
-}
introduction : Html Msg
introduction =
    div [ class "api-tokens-intro" ]
        [ p []
            [ text "An API token lets your own code read your course data — a script, a notebook, or an AI assistant writing code with you. Send it to the course API as a header:" ]
        , code [ class "api-token-usage" ] [ text "Authorization: Bearer <your token>" ]
        , p []
            [ text "If you only want an assistant to read your data, connect it over MCP instead — that needs no token at all." ]
        ]


{-| The secret exists outside the database exactly once, here. Say so in terms
that cannot be misread, because the alternative to reading this carefully is a
student pasting a four-month credential into a public repository.
-}
justCreatedView : Maybe CreatedToken -> Html Msg
justCreatedView justCreated =
    case justCreated of
        Nothing ->
            text ""

        Just created ->
            div [ class "api-token-created" ]
                [ h2 [] [ text ("Token created: " ++ created.name) ]
                , p [ class "api-token-warning" ]
                    [ text "Copy this now. It will not be shown again." ]
                , div [ class "api-token-secret-row" ]
                    [ code [ class "api-token-secret" ] [ text created.token ]

                    -- The click handler in init.js copies any element
                    -- carrying data-copy-text, which is how the dashboard
                    -- reveals user secrets. A token shown once and never
                    -- again is the last place to make someone select it by
                    -- hand.
                    , button
                        [ type_ "button"
                        , attribute "data-copy-text" created.token
                        , attribute "aria-label" ("copy the token " ++ created.name)
                        ]
                        [ text "Copy" ]
                    ]
                , p []
                    [ text "Treat it like a password: do not commit it, and do not paste it into Canvas, Slack or Piazza. It expires "
                    , text (shortDate created.expiresAt)
                    , text ", and you can revoke it below at any time."
                    ]
                , button [ onClick Msgs.DismissCreatedApiToken ] [ text "I have copied it" ]
                ]


createFormView : String -> Set String -> Html Msg
createFormView draftName draftScopes =
    div [ class "api-token-create" ]
        [ h2 [] [ text "Create a token" ]
        , div [ class "api-token-field" ]
            [ label [ class "api-token-field-label", for "api-token-name" ] [ text "Name" ]
            , input
                [ id "api-token-name"
                , type_ "text"
                , placeholder "laptop, colab, final project…"
                , value draftName
                , onInput Msgs.SetApiTokenDraftName
                ]
                []
            ]

        -- A fieldset with a legend, rather than a div with a loose text node
        -- for a heading. The text node had no box of its own, so it ran
        -- straight into the first scope and the whole list read as one
        -- sentence.
        , fieldset [ class "api-token-scopes" ]
            (legend [] [ text "What it may do" ] :: List.map (scopeCheckbox draftScopes) allScopes)
        , button
            [ onClick Msgs.CreateApiToken
            , disabled (String.trim draftName == "" || Set.isEmpty draftScopes)
            ]
            [ text "Create token" ]
        ]


scopeCheckbox : Set String -> String -> Html Msg
scopeCheckbox draftScopes scope =
    let
        -- The write scope is the boundary worth drawing a person's eye to: it
        -- is the difference between a token that can read your work and one
        -- that can submit it.
        emphasis =
            if scope == writeScope then
                " api-token-scope-write"

            else
                ""
    in
    label [ class ("api-token-scope" ++ emphasis) ]
        [ input
            [ type_ "checkbox"
            , checked (Set.member scope draftScopes)
            , onCheck (Msgs.SetApiTokenDraftScope scope)
            ]
            []
        , span [ class "api-token-scope-name" ] [ text scope ]
        , span [ class "api-token-scope-description" ] [ text (scopeDescription scope) ]
        ]


tokenTableView : WebData (List ApiToken) -> Set Int -> Html Msg
tokenTableView tokens pendingRevokes =
    case tokens of
        RemoteData.NotAsked ->
            text ""

        RemoteData.Loading ->
            p [] [ text "Loading…" ]

        RemoteData.Failure _ ->
            p [ class "error" ] [ text "Could not load your tokens." ]

        RemoteData.Success [] ->
            p [] [ text "You have no API tokens." ]

        RemoteData.Success list ->
            table [ class "api-token-table" ]
                [ thead []
                    [ tr []
                        [ th [] [ text "Name" ]
                        , th [] [ text "Prefix" ]
                        , th [] [ text "Scopes" ]
                        , th [] [ text "Last used" ]
                        , th [] [ text "Expires" ]
                        , th [] [ text "" ]
                        ]
                    ]
                , tbody [] (List.map (tokenRow pendingRevokes) list)
                ]


tokenRow : Set Int -> ApiToken -> Html Msg
tokenRow pendingRevokes token =
    let
        status =
            if token.revokedAt /= Nothing then
                "revoked"

            else if not token.isActive then
                "expired"

            else
                "active"
    in
    tr [ class ("api-token-row api-token-" ++ status) ]
        [ td [] [ text token.name ]
        , td [] [ code [] [ text token.tokenPrefix ] ]
        , td [] [ ul [] (List.map (\s -> li [] [ text s ]) token.scopes) ]

        -- Never used is worth saying out loud rather than leaving blank: a
        -- token that has never been used and is not expected to be is one to
        -- revoke.
        , td []
            [ text
                (case token.lastUsedAt of
                    Nothing ->
                        "never"

                    Just used ->
                        shortDate used
                )
            ]
        , td [] [ text (shortDate token.expiresAt) ]
        , td []
            [ if status == "active" then
                button
                    [ onClick (Msgs.RevokeApiToken token.id)
                    , disabled (Set.member token.id pendingRevokes)
                    ]
                    [ text
                        (if Set.member token.id pendingRevokes then
                            "Revoking…"

                         else
                            "Revoke"
                        )
                    ]

              else
                span [ class "api-token-status" ] [ text status ]
            ]
        ]


{-| The API returns full ISO timestamps; only the date is useful here.
-}
shortDate : String -> String
shortDate iso =
    String.left 10 iso
