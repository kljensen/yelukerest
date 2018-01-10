module Routing exposing (..)

import Models exposing (Route(..))
import Navigation exposing (Location)
import Players.Model exposing (PlayerId)
import UrlParser exposing ((</>), Parser, map, oneOf, parseHash, s, string, top)


matchers : Parser (Route -> a) a
matchers =
    oneOf
        [ map MeetingListRoute top
        , map PlayerRoute (s "players" </> string)
        , map PlayersRoute (s "players")
        , map MeetingListRoute (s "meetings")
        , map MeetingDetailRoute (s "meetings" </> string)
        ]


parseLocation : Location -> Route
parseLocation location =
    case parseHash matchers location of
        Just route ->
            route

        Nothing ->
            NotFoundRoute


playersPath : String
playersPath =
    "#players"


playerPath : PlayerId -> String
playerPath id =
    "#players/" ++ id
