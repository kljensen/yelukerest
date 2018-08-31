module Common.Comparisons exposing (dateIsLessThan)

import Date exposing (Date)


dateIsLessThan : Date -> Date -> Bool
dateIsLessThan a b =
    case Basics.compare (Date.toTime a) (Date.toTime b) of
        LT ->
            True

        _ ->
            False
