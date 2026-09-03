module Mcp.Views exposing (page)

import Html exposing (Html, a, button, code, div, h1, h2, li, p, strong, text, ul)
import Html.Attributes exposing (attribute, class, href, target, type_)
import Msgs exposing (Msg)


{-| How to connect an AI assistant to this course, over MCP.

Static content. The one thing that is not static is the endpoint, which is
built from the origin the browser is already on, so there is no
`<course-site>` for anyone to mis-substitute.

This page states only what is durable -- the address, the network rule, the
one consent decision -- and LINKS to each vendor's own setup page for the
clicks and commands. It used to embed those. Vendor CLIs and settings screens
change several times a year, and an embedded recipe is wrong the moment they
do, while the vendor's page is maintained by the people who changed it.

No link to `docs/mcp-for-students.md`: it lives in a private repository, so
every student following it would land on a 404 while being told it was their
own sign-in that was wrong.

-}
page : String -> Html Msg
page endpoint =
    div [ class "mcp" ]
        [ h1 [] [ text "Connect an AI assistant" ]
        , introduction
        , networkView
        , endpointView endpoint
        , setupView
        , writeScopeView
        ]


introduction : Html Msg
introduction =
    p []
        [ text "You can connect an AI assistant to your course data, so it can see your meetings, assignments, submissions and grades while it works with you. There is no token to create — you sign in with CAS, as you did to reach this page, and approve what the assistant may do." ]


{-| The precondition that decides whether any of the rest works, so it goes
before the address. The course's MCP and API endpoints are reachable only
from the Yale network. What matters is where the HTTP request comes FROM: an
assistant running on the student's laptop sends it from the laptop, which is
on the network; a website such as claude.ai or chatgpt.com sends it from the
vendor's servers, which are not.
-}
networkView : Html Msg
networkView =
    div [ class "mcp-network" ]
        [ h2 [] [ text "Yale network only" ]
        , p []
            [ text "The course's MCP and API addresses can only be reached from the Yale network. Be on campus, or on the "
            , strong [] [ text "Yale VPN" ]
            , text ", whenever your assistant talks to the course."
            ]
        , p []
            [ text "What matters is which computer sends the request. An assistant "
            , strong [] [ text "running on your own machine" ]
            , text " — Claude Code, Codex — sends it from your machine, which is on the network. The "
            , strong [] [ text "claude.ai and ChatGPT websites" ]
            , text " send it from the vendor's servers, which are not, so a connector added there will fail even though you are signed in."
            ]
        ]


endpointView : String -> Html Msg
endpointView endpoint =
    div []
        [ h2 [] [ text "The address" ]
        , copyRow endpoint "copy the course MCP address"
        , p []
            [ text "This is a remote MCP server that signs you in through your browser (OAuth). When a setup page asks for a URL, this is it. When it asks for a name, that name is a label in your own configuration and can be anything — "
            , code [] [ text "mgt656-fall-2026" ]
            , text " is a good one. Adding the address is not yet connecting: each tool has a second step that opens the browser for CAS and the consent page."
            ]
        ]


{-| A thing to copy, in the shape the API tokens page uses for a new token:
the text on the left, its copy button on the right. The click handler in
init.js copies any element carrying data-copy-text.
-}
copyRow : String -> String -> Html Msg
copyRow body label =
    div [ class "mcp-copy-row" ]
        [ code [ class "mcp-copyable" ] [ text body ]
        , button
            [ type_ "button"
            , attribute "data-copy-text" body
            , attribute "aria-label" label
            ]
            [ text "Copy" ]
        ]


{-| Links, not recipes. Each entry is the vendor's own page for adding a
remote MCP server, checked to exist and to cover the OAuth sign-in when this
was written. The Claude Code desktop app reads the same configuration the
terminal writes, which is why its entry points at the terminal page as well.
-}
setupView : Html Msg
setupView =
    div []
        [ h2 [] [ text "Setting it up" ]
        , p [] [ text "Follow the vendor's own instructions for adding a remote MCP server, and give it the address above:" ]
        , ul [ class "mcp-setup-links" ]
            [ li []
                [ vendorLink "https://code.claude.com/docs/en/mcp" "Claude Code in the terminal"
                , text " — add the server, then run "
                , code [] [ text "/mcp" ]
                , text " to sign in."
                ]
            , li []
                [ vendorLink "https://code.claude.com/docs/en/desktop#connect-external-tools" "Claude Code desktop app"
                , text " — it uses the same configuration as the terminal, so the terminal page's steps apply. Do not add the course as a claude.ai connector: those run through Anthropic's servers, which are off the Yale network."
                ]
            , li []
                [ vendorLink "https://learn.chatgpt.com/docs/extend/mcp" "Codex"
                , text " — one page covering the terminal, the desktop app and the IDE extension. Add the server, then sign in with "
                , code [] [ text "codex mcp login" ]
                , text "."
                ]
            ]
        , p [] [ text "Whichever you use, the sign-in is the same: a browser window opens on Yale CAS, then a consent page from this site lists what the assistant may do. Access renews on its own afterwards, as long as your computer is on the Yale network when it does." ]
        ]


vendorLink : String -> String -> Html Msg
vendorLink url label =
    a [ href url, target "_blank" ] [ text label ]


{-| The one real decision on the consent page, given the emphasis the API
tokens page gives the same scope. The team sentence is the one that must not
be softened: the write scope reaches a team's shared submission, so the
person ticking the box is deciding for people who were never asked.
-}
writeScopeView : Html Msg
writeScopeView =
    div [ class "mcp-write" ]
        [ h2 [] [ text "The one decision" ]
        , p []
            [ text "The consent page asks for reading your course data. It also offers "
            , code [ class "mcp-write-scope" ] [ text "submissions:write" ]
            , text ", which starts unchecked. Ticking it lets the assistant create and change submissions in your name — "
            , strong [] [ text "including your team's shared submissions on team assignments" ]
            , text ", which your teammates rely on and were never asked about."
            ]
        , p []
            [ text "Nothing asks you again at the moment a write happens. Some assistants show a confirmation of their own before they act; that is a feature of that app, not a protection this site enforces. Leave the box unchecked unless you want an assistant able to submit for you and for your team." ]
        , p []
            [ text "You can see what you have connected, and disconnect any of it, on "
            , a [ href "#/connected-apps" ] [ text "Connected apps" ]
            , text ". If you want your own script or notebook to read your data instead of an assistant, create an "
            , a [ href "#/api-tokens" ] [ text "API token" ]
            , text "."
            ]
        ]
