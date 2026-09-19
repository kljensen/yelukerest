module Routing exposing (matchers, parseLocation)

import Assignments.Model exposing (githubJoinResult)
import Models exposing (Route(..))
import Msgs exposing (BrowserLocation(..))
import Url exposing (Url)
import Url.Parser exposing ((</>), (<?>), Parser, map, oneOf, parse, s, string, top)
import Url.Parser.Query as Query
import Assignments.Views exposing (gradeView)


matchers : Parser (Route -> a) a
matchers =
    oneOf
        [ map IndexRoute top
        , map CurrentUserDashboardRoute (s "dashboard")
        , map MeetingListRoute (s "meetings")
        , map MeetingDetailRoute (s "meetings" </> string)
        , map AssignmentListRoute (s "assignments")
        , map assignmentRoute (s "assignments" </> string <?> Query.string "github_join")
        , map AssignmentGradeDetailRoute (s "assignments" </> string </> s "grade" )
        , map EditEngagementsRoute (s "engagements" </> string)
        , map ConnectedAppsRoute (s "connected-apps")
        , map ApiTokensRoute (s "api-tokens")
        , map DataGrantsRoute (s "data-grants")
        , map McpRoute (s "mcp")
        ]


{-| The assignment page, or the same page as the GitHub join sends the
student back to it (`#/assignments/<slug>?github_join=<marker>`).
-}
assignmentRoute : String -> Maybe String -> Route
assignmentRoute slug marker =
    case Maybe.andThen githubJoinResult marker of
        Just result ->
            AssignmentJoinReturnRoute slug result

        Nothing ->
            AssignmentDetailRoute slug


parseHash : Url -> Maybe Route
parseHash url =
    let
        fragment =
            Maybe.withDefault "" url.fragment

        -- Overwrite the URL's path (and query) with the fragment component,
        -- solely for the purposes of parsing. A query inside the fragment
        -- is the fragment's own, not the page's.
        fakeURL =
            case String.split "?" fragment of
                path :: query :: _ ->
                    { url | path = path, query = Just query, fragment = Nothing }

                _ ->
                    { url | path = fragment, query = Nothing, fragment = Nothing }

        route =
            parse matchers fakeURL
    in
    case ( url.fragment, url.path ) of
        ( Nothing, "/" ) ->
            route

        ( Nothing, _ ) ->
            Nothing

        ( Just f, _ ) ->
            route


parseLocation : BrowserLocation -> Route
parseLocation location =
    let
        theLocation =
            case location of
                StringLocation loc ->
                    Url.fromString loc

                UrlLocation loc ->
                    Just loc
    in
    case theLocation of
        Just url ->
            case parseHash url of
                Just route ->
                    route

                Nothing ->
                    NotFoundRoute

        Nothing ->
            NotFoundRoute
