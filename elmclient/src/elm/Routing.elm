module Routing exposing (matchers, parseLocation)

import Models exposing (Route(..))
import Msgs exposing (BrowserLocation(..))
import Url exposing (Url)
import Url.Parser exposing ((</>), Parser, int, map, oneOf, parse, s, string, top)


matchers : Parser (Route -> a) a
matchers =
    oneOf
        [ map IndexRoute top
        , map CurrentUserDashboardRoute (s "dashboard")
        , map MeetingListRoute (s "meetings")
        , map MeetingDetailRoute (s "meetings" </> string)
        , map AssignmentListRoute (s "assignments")
        , map AssignmentDetailRoute (s "assignments" </> string)
        , map TakeQuizRoute (s "quiz-submissions" </> int)
        , map EditEngagementsRoute (s "engagements" </> int)
        ]


parseHash : Url -> Maybe Route
parseHash url =
    let
        -- Overwrite the URL's path with the fragment component, solely
        -- for the purposes of parsing.
        fakeURL =
            { url | path = Maybe.withDefault "" url.fragment, fragment = Nothing }

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
