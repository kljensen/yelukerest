module Players.Model exposing (PlayerId, Player)

type alias PlayerId =
    String


type alias Player =
    { id : PlayerId
    , name : String
    , level : Int
    }
