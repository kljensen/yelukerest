module Mcp.Views exposing (page)

import Html exposing (Html, a, button, code, div, h1, h2, li, ol, p, text)
import Html.Attributes exposing (attribute, class, href, type_)
import Msgs exposing (Msg)


{-| How to connect an AI assistant to this course, over MCP.

Static content. The one thing that is not static is the endpoint, which is
built from the origin the browser is already on, so there is no
`<course-site>` for anyone to mis-substitute.

No link to `docs/mcp-for-students.md`: it lives in a private repository, so
every student following it would land on a 404 while being told it was their
own sign-in that was wrong -- the same trap already removed from the API
tokens page.

-}
page : String -> Html Msg
page endpoint =
    div [ class "mcp" ]
        [ h1 [] [ text "Connect an AI assistant" ]
        , introduction
        , endpointView endpoint
        , stepsView
        , commandLineView endpoint
        , guiClientView
        , writeScopeView
        ]


introduction : Html Msg
introduction =
    p []
        [ text "You can connect an AI assistant — Claude, ChatGPT, or anything else that speaks MCP — to your course data, so it can see your meetings, assignments, submissions and grades while it works with you. There is no token to create and nothing to paste into a configuration file: you sign in with CAS, as you did to reach this page, and approve what the assistant may do." ]


endpointView : String -> Html Msg
endpointView endpoint =
    div []
        [ h2 [] [ text "The address" ]
        , div [ class "mcp-endpoint-row" ]
            [ code [ class "mcp-endpoint" ] [ text endpoint ]

            -- The click handler in init.js copies any element carrying
            -- data-copy-text, which is how the dashboard reveals user secrets
            -- and how the API tokens page hands over a new token.
            , button
                [ type_ "button"
                , attribute "data-copy-text" endpoint
                , attribute "aria-label" "copy the course MCP address"
                ]
                [ text "Copy" ]
            ]
        ]


stepsView : Html Msg
stepsView =
    div []
        [ h2 [] [ text "Three steps" ]
        , ol [ class "mcp-steps" ]
            [ li [] [ text "Point your assistant at the address above." ]
            , li [] [ text "A browser window opens. Log in with CAS, the same way you log in here." ]
            , li [] [ text "Approve the consent page, which lists exactly what the assistant may do." ]
            ]
        , p [] [ text "That is the whole setup. If the connection ever stops working, repeat it — there is nothing to renew by hand." ]
        ]


commandLineView : String -> Html Msg
commandLineView endpoint =
    let
        command =
            "claude mcp add --transport http mgt656-fall-2026 " ++ endpoint
    in
    div []
        [ h2 [] [ text "Claude Code" ]
        , div [ class "mcp-endpoint-row" ]
            [ code [ class "mcp-endpoint" ] [ text command ]
            , button
                [ type_ "button"
                , attribute "data-copy-text" command
                , attribute "aria-label" "copy the claude mcp add command"
                ]
                [ text "Copy" ]
            ]
        , p []
            [ code [] [ text "mgt656-fall-2026" ]
            , text " is a label in your own configuration, not the server's name. It is what you will type when you refer to this connection, so call it whatever you like — and if you already have a working connection under a different name, leave it as it is."
            ]
        ]


guiClientView : Html Msg
guiClientView =
    div []
        [ h2 [] [ text "Claude Desktop, claude.ai, ChatGPT" ]
        , p []
            [ text "In an app with a settings screen, add a custom connector and give it the address above. The wording varies by app — connector, integration, MCP server — and changes often, so look for whichever of those your app calls it." ]
        ]


{-| The one real decision on the consent page, given the emphasis the API
tokens page gives the same scope: reading is what most people want, and
writing is a different thing entirely.
-}
writeScopeView : Html Msg
writeScopeView =
    div [ class "mcp-write" ]
        [ h2 [] [ text "The one decision" ]
        , p []
            [ text "The consent page asks for reading your course data. It also offers "
            , code [ class "mcp-write-scope" ] [ text "submissions:write" ]
            , text ", which starts unchecked. Ticking it lets the assistant submit work in your name."
            ]
        , p []
            [ text "Nothing asks you again at the moment a write happens. Some assistants show a confirmation of their own before they act; that is a feature of that app, not a protection this site enforces. Leave the box unchecked unless you want an assistant able to submit for you." ]
        , p []
            [ text "You can see what you have connected, and disconnect any of it, on "
            , a [ href "#/connected-apps" ] [ text "Connected apps" ]
            , text ". If you want your own script or notebook to read your data instead of an assistant, create an "
            , a [ href "#/api-tokens" ] [ text "API token" ]
            , text "."
            ]
        ]
