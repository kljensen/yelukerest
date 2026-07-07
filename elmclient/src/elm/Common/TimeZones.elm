module Common.TimeZones exposing (zoneForZoneName)

import Time exposing (Zone, ZoneName(..))


zoneForZoneName : ZoneName -> Zone -> Zone
zoneForZoneName zoneName fallbackZone =
    case zoneName of
        Name "America/New_York" ->
            americaNewYork

        Name "US/Eastern" ->
            americaNewYork

        _ ->
            fallbackZone


americaNewYork : Zone
americaNewYork =
    Time.customZone (-300) (List.reverse americaNewYorkTransitions)


americaNewYorkTransitions : List { start : Int, offset : Int }
americaNewYorkTransitions =
    -- US Eastern DST transitions, generated through 2050.
    [ { start = 25345860, offset = -240 }
    , { start = 25688520, offset = -300 }
    , { start = 25870020, offset = -240 }
    , { start = 26212680, offset = -300 }
    , { start = 26394180, offset = -240 }
    , { start = 26736840, offset = -300 }
    , { start = 26928420, offset = -240 }
    , { start = 27271080, offset = -300 }
    , { start = 27452580, offset = -240 }
    , { start = 27795240, offset = -300 }
    , { start = 27976740, offset = -240 }
    , { start = 28319400, offset = -300 }
    , { start = 28500900, offset = -240 }
    , { start = 28843560, offset = -300 }
    , { start = 29025060, offset = -240 }
    , { start = 29367720, offset = -300 }
    , { start = 29549220, offset = -240 }
    , { start = 29891880, offset = -300 }
    , { start = 30083460, offset = -240 }
    , { start = 30426120, offset = -300 }
    , { start = 30607620, offset = -240 }
    , { start = 30950280, offset = -300 }
    , { start = 31131780, offset = -240 }
    , { start = 31474440, offset = -300 }
    , { start = 31655940, offset = -240 }
    , { start = 31998600, offset = -300 }
    , { start = 32180100, offset = -240 }
    , { start = 32522760, offset = -300 }
    , { start = 32714340, offset = -240 }
    , { start = 33057000, offset = -300 }
    , { start = 33238500, offset = -240 }
    , { start = 33581160, offset = -300 }
    , { start = 33762660, offset = -240 }
    , { start = 34105320, offset = -300 }
    , { start = 34286820, offset = -240 }
    , { start = 34629480, offset = -300 }
    , { start = 34810980, offset = -240 }
    , { start = 35153640, offset = -300 }
    , { start = 35335140, offset = -240 }
    , { start = 35677800, offset = -300 }
    , { start = 35869380, offset = -240 }
    , { start = 36212040, offset = -300 }
    , { start = 36393540, offset = -240 }
    , { start = 36736200, offset = -300 }
    , { start = 36917700, offset = -240 }
    , { start = 37260360, offset = -300 }
    , { start = 37441860, offset = -240 }
    , { start = 37784520, offset = -300 }
    , { start = 37966020, offset = -240 }
    , { start = 38308680, offset = -300 }
    , { start = 38490180, offset = -240 }
    , { start = 38832840, offset = -300 }
    , { start = 39024420, offset = -240 }
    , { start = 39367080, offset = -300 }
    , { start = 39548580, offset = -240 }
    , { start = 39891240, offset = -300 }
    , { start = 40072740, offset = -240 }
    , { start = 40415400, offset = -300 }
    , { start = 40596900, offset = -240 }
    , { start = 40939560, offset = -300 }
    , { start = 41121060, offset = -240 }
    , { start = 41463720, offset = -300 }
    , { start = 41655300, offset = -240 }
    , { start = 41997960, offset = -300 }
    , { start = 42179460, offset = -240 }
    , { start = 42522120, offset = -300 }
    ]
