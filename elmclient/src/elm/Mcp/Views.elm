module Mcp.Views exposing (page)

import Html exposing (Html, a, button, code, div, h1, h2, li, ol, p, pre, strong, text)
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
        , networkView
        , endpointView endpoint
        , stepsView
        , commandLineView endpoint
        , codexView endpoint
        , guiClientView
        , bridgeView endpoint
        , writeScopeView
        ]


{-| The endpoint speaks HTTP and signs a person in through the browser, and
accepts nothing else. Saying "anything that speaks MCP" would send the
stdio-only clients down three steps that cannot work for them; the bridge
they need has its own section below.

ChatGPT is named with a caveat rather than in the list: whether it can add a
connector at all depends on the plan and the workspace. Which plans is not
something this page can state and keep true, so it says what does not go
stale -- that it depends -- rather than a tier that will have moved by the
time somebody reads it.

-}
introduction : Html Msg
introduction =
    p []
        [ text "You can connect an AI assistant to your course data, so it can see your meetings, assignments, submissions and grades while it works with you. This works with assistants that run on your own computer and can open a browser to sign you in: Claude Code, Codex and Claude Desktop all can. There is no token to create — you sign in with CAS, as you did to reach this page, and approve what the assistant may do." ]


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
            , text " — Claude Code, Codex, Claude Desktop — sends it from your machine, which is on the network. The "
            , strong [] [ text "claude.ai and ChatGPT websites" ]
            , text " send it from the vendor's servers, which are not, so a connector added there will fail even though you are signed in. Use one of the desktop or terminal tools below instead."
            ]
        ]


endpointView : String -> Html Msg
endpointView endpoint =
    div []
        [ h2 [] [ text "The address" ]
        , copyRow endpoint "copy the course MCP address"
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


{-| Step two is the one people miss: giving an assistant the address does not
connect it. In Claude Code that is a separate command, and until it is run
nothing has signed in and nothing has been approved.
-}
stepsView : Html Msg
stepsView =
    div []
        [ h2 [] [ text "Three steps" ]
        , ol [ class "mcp-steps" ]
            [ li [] [ text "Give your assistant the address above." ]
            , li [] [ text "Tell it to connect. Adding the address is not connecting: in Claude Code that is a second command, and in an app with a settings screen it happens as you finish adding the connector." ]
            , li [] [ text "A browser window opens. Log in with CAS, the same way you log in here, and approve the consent page, which lists exactly what the assistant may do." ]
            ]
        , p [] [ text "That is the whole setup — nothing to renew by hand afterwards. If the connection ever stops working, do it again." ]
        ]


commandLineView : String -> Html Msg
commandLineView endpoint =
    div []
        [ h2 [] [ text "Claude Code" ]
        , p [] [ text "Register the address:" ]
        , copyRow ("claude mcp add --transport http mgt656-fall-2026 " ++ endpoint)
            "copy the claude mcp add command"
        , p []
            [ text "That command only records where the course is; nothing has signed in yet, and it will report success either way. Then, inside Claude Code, run "
            , code [] [ text "/mcp" ]
            , text ", choose "
            , code [] [ text "mgt656-fall-2026" ]
            , text " from the list, and authenticate. That is the step that opens the browser for CAS and the consent page. Afterwards Claude Code renews access on its own."
            ]
        , p []
            [ code [] [ text "mgt656-fall-2026" ]
            , text " is a label in your own configuration, not the server's name. It is what you will pick from that list, so call it whatever you like — and if you already have a working connection under a different name, leave it as it is."
            ]
        ]


{-| OpenAI's terminal tool. Same shape as Claude Code: one command records
the address, a second one signs in.
-}
codexView : String -> Html Msg
codexView endpoint =
    let
        add =
            "codex mcp add mgt656-fall-2026 --url " ++ endpoint

        login =
            "codex mcp login mgt656-fall-2026"
    in
    div []
        [ h2 [] [ text "Codex" ]
        , p [] [ text "Register the address:" ]
        , copyRow add "copy the codex mcp add command"
        , p [] [ text "Then sign in. This is the step that opens the browser for CAS and the consent page:" ]
        , copyRow login "copy the codex mcp login command"
        , p []
            [ text "As with Claude Code, "
            , code [] [ text "mgt656-fall-2026" ]
            , text " is a label in your own configuration and can be anything you like."
            ]
        ]


guiClientView : Html Msg
guiClientView =
    div []
        [ h2 [] [ text "Claude Desktop" ]
        , p []
            [ text "Claude Desktop runs on your machine, so it can reach the course. Use the bridge configuration below: it launches a small program on your computer that does the sign-in and talks to the course from there." ]
        , p []
            [ text "The claude.ai and ChatGPT websites cannot be used, whatever your plan: their requests come from the vendor's servers, not from your computer, and the course does not answer them. For ChatGPT, use Codex on your machine instead." ]
        ]


{-| Some clients only speak stdio: they launch a local program and talk to it
over a pipe, and can neither open a browser nor hold a session. The endpoint
accepts the browser sign-in and nothing else, so those clients need a bridge
in front of it rather than a different set of steps.
-}
bridgeView : String -> Html Msg
bridgeView endpoint =
    let
        config =
            String.join "\n"
                [ "{"
                , "  \"mcpServers\": {"
                , "    \"mgt656-fall-2026\": {"
                , "      \"command\": \"npx\","
                , "      \"args\": [\"-y\", \"mcp-remote\", \"" ++ endpoint ++ "\"]"
                , "    }"
                , "  }"
                , "}"
                ]
    in
    div []
        [ h2 [] [ text "Claude Desktop, and any app that cannot open a browser" ]
        , p []
            [ text "Some assistants only launch a local program and talk to it over a pipe. They cannot sign you in, and this address accepts nothing else. Put "
            , code [] [ text "mcp-remote" ]
            , text " in front of it: your app launches the bridge, and the bridge does the browser sign-in and talks to the course on its behalf. Clients that take an "
            , code [] [ text "mcpServers" ]
            , text " JSON configuration — Claude Desktop is the one most people mean — want this:"
            ]
        , div [ class "mcp-copy-row" ]
            [ pre [ class "mcp-copyable" ] [ text config ]
            , button
                [ type_ "button"
                , attribute "data-copy-text" config
                , attribute "aria-label" "copy the mcp-remote configuration"
                ]
                [ text "Copy" ]
            ]
        , p [] [ text "Other clients keep their configuration in their own format and their own place; follow that client's MCP setup instructions and give it the same bridge command. The address is the part that does not change." ]
        , p [] [ text "The first run opens a browser for CAS and the consent page, exactly as above, and renews itself after that — as long as your computer is on the Yale network when it does." ]
        ]


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
