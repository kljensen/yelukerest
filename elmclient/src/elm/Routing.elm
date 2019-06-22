module Routing exposing (matchers, parseLocation)

import Models exposing (Route(..))
import Url exposing (Url)
import Url.Parser exposing ((</>), Parser, int, map, oneOf, parseHash, s, string, top)


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


parseLocation : Location -> Route
parseLocation location =
    case parseHash matchers location of
        Just route ->
            route

        Nothing ->
            NotFoundRoute
