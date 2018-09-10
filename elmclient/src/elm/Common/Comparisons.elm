module Common.Comparisons
    exposing
        ( dateIsLessThan
        , sortByDate
        )

import Date exposing (Date)


dateIsLessThan : Date -> Date -> Bool
dateIsLessThan a b =
    case Basics.compare (Date.toTime a) (Date.toTime b) of
        LT ->
            True

        _ ->
            False


{-| Returns the sort order betweek `f(x)` and `f(y)`
where `f()` returns a Date for type `a` and `x`
and `y` are both of type `a`.
-}
fieldDateCompare : (a -> Date) -> a -> a -> Order
fieldDateCompare f x y =
    Basics.compare (Date.toTime (f x)) (Date.toTime (f y))


sortByDate : (a -> Date) -> List a -> List a
sortByDate f x =
    List.sortWith (fieldDateCompare f) x
