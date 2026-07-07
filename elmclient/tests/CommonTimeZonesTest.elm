module CommonTimeZonesTest exposing (tests)

import Common.TimeZones
import Common.Views
import Expect
import Models exposing (TimeZone)
import Test exposing (Test, describe, test)
import Time exposing (ZoneName(..))


tests : Test
tests =
    describe "Common.TimeZones"
        [ test "America/New_York formats future standard-time dates after fall DST transition" <|
            \_ ->
                Common.Views.longDateToString issue83DueDate newYorkTimeZone
                    |> Expect.equal "07:00pm Thursday (America/New_York), November 7, 2019"
        , test "America/New_York preserves daylight time before the fall DST transition" <|
            \_ ->
                issue83BeforeTransition
                    |> Time.toHour newYorkTimeZone.zone
                    |> Expect.equal 19
        , test "America/New_York switches to standard time at the 2019 fall transition" <|
            \_ ->
                Time.toHour newYorkTimeZone.zone (Time.millisToPosix 1572760860000)
                    |> Expect.equal 1
        ]


newYorkTimeZone : TimeZone
newYorkTimeZone =
    { zone = Common.TimeZones.zoneForZoneName (Name "America/New_York") Time.utc
    , zoneName = Name "America/New_York"
    }


issue83DueDate : Time.Posix
issue83DueDate =
    Time.millisToPosix 1573171200000


issue83BeforeTransition : Time.Posix
issue83BeforeTransition =
    Time.millisToPosix 1572476400000
