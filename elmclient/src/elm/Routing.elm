module Routing exposing (..)

import Models exposing (Route(..))
import Navigation exposing (Location)
import UrlParser exposing ((</>), Parser, map, oneOf, parseHash, s, string, top)


matchers : Parser (Route -> a) a
matchers =
    oneOf
        [ map IndexRoute top
        , map CurrentUserDashboardRoute (s "dashboard")
        , map MeetingListRoute (s "meetings")
        , map MeetingDetailRoute (s "meetings" </> string)
        , map AssignmentListRoute (s "assignments")
        , map AssignmentDetailRoute (s "assignments" </> string)
        ]


parseLocation : Location -> Route
parseLocation location =
    case parseHash matchers location of
        Just route ->
            route

        Nothing ->
            NotFoundRoute
