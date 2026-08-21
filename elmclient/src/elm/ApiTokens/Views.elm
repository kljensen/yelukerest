module ApiTokens.Views exposing (listView)

import ApiTokens.Model exposing (ApiToken, CreatedToken, allScopes, scopeDescription, writeScope)
import Html exposing (Html, a, button, code, div, h1, h2, input, label, li, p, span, table, tbody, td, text, th, thead, tr, ul)
import Html.Attributes exposing (checked, class, disabled, href, placeholder, type_, value)
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


introduction : Html Msg
introduction =
    div [ class "api-tokens-intro" ]
        [ p []
            [ text "An API token lets your own code read your course data — a script, a notebook, or an AI assistant writing code with you. "
            , a [ href "https://github.com/kljensen/yelukerest/blob/main/docs/personal-access-tokens.md" ]
                [ text "How to use one" ]
            , text "."
            ]
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
                , code [ class "api-token-secret" ] [ text created.token ]
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
        , label []
            [ text "Name"
            , input
                [ type_ "text"
                , placeholder "laptop, colab, final project…"
                , value draftName
                , onInput Msgs.SetApiTokenDraftName
                ]
                []
            ]
        , div [ class "api-token-scopes" ]
            (text "What it may do" :: List.map (scopeCheckbox draftScopes) allScopes)
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
