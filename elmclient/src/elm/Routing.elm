module Routing exposing (matchers, parseLocation)

import Models exposing (Route(..))
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
    -- The RealWorld spec treats the fragment like a path.
    -- This makes it *literally* the path, so we can proceed
    -- with parsing as if it had been a normal path all along.
    { url | path = Maybe.withDefault "" url.fragment, fragment = Nothing }
        |> parse matchers


parseLocation : String -> Route
parseLocation location =
    let
        loc =
            Url.fromString location
    in
    case loc of
        Just url ->
            case parseHash url of
                Just route ->
                    route

                Nothing ->
                    NotFoundRoute

        Nothing ->
            NotFoundRoute
