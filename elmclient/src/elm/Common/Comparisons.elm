module Common.Comparisons exposing
    ( dateIsLessThan
    , sortByDate
    )

import Time exposing (Posix, posixToMillis)


dateIsLessThan : Posix -> Posix -> Bool
dateIsLessThan a b =
    case Basics.compare (posixToMillis a) (posixToMillis b) of
        LT ->
            True

        _ ->
            False


{-| Returns the sort order betweek `f(x)` and `f(y)`
where `f()` returns a Posix for type `a` and `x`
and `y` are both of type `a`.
-}
fieldDateCompare : (a -> Posix) -> a -> a -> Order
fieldDateCompare f x y =
    Basics.compare (posixToMillis (f x)) (posixToMillis (f y))


sortByDate : (a -> Posix) -> List a -> List a
sortByDate f x =
    List.sortWith (fieldDateCompare f) x
