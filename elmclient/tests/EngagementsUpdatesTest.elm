module EngagementsUpdatesTest exposing (tests)

import Dict exposing (Dict)
import Engagements.Model exposing (Engagement, PendingSubmit(..))
import Engagements.Updates
    exposing
        ( EngagementState
        , onChangeEngagement
        , onSubmitEngagementResponse
        )
import Expect
import Http
import RemoteData exposing (WebData)
import Test exposing (Test, describe, test)
import Time


{-| Recording attendance is a live activity: faculty click through a roster and
read back the highlighted value to see what is stored. The view derives that
highlight from `engagements`, so a save that only clears the pending entry
leaves the page showing the old value until a full reload.
-}
tests : Test
tests =
    describe "Engagements.Updates"
        [ describe "a successful save"
            [ test "replaces the stored engagement" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> saved "led"
                        |> participationFor meetingSlug userID
                        |> Expect.equal (Just "led")
            , test "does not lengthen the list it replaces into" <|
                \_ ->
                    clicked "led" (stateWith [ absent, otherStudent ])
                        |> saved "led"
                        |> engagementCount
                        |> Expect.equal 2
            , test "adds an engagement for someone with no record yet" <|
                \_ ->
                    clicked "led" (stateWith [ otherStudent ])
                        |> saved "led"
                        |> participationFor meetingSlug userID
                        |> Expect.equal (Just "led")
            , test "adding one leaves the engagements already there" <|
                \_ ->
                    clicked "led" (stateWith [ otherStudent ])
                        |> saved "led"
                        |> engagementCount
                        |> Expect.equal 2
            , test "leaves another student at the same meeting alone" <|
                \_ ->
                    clicked "led" (stateWith [ absent, otherStudent ])
                        |> saved "led"
                        |> participationFor meetingSlug otherStudent.user_id
                        |> Expect.equal (Just "attended")
            , test "leaves the same student at another meeting alone" <|
                \_ ->
                    clicked "led" (stateWith [ absent, sameStudentOtherMeeting ])
                        |> saved "led"
                        |> participationFor otherMeetingSlug userID
                        |> Expect.equal (Just "contributed")

            -- The server upserts on (user, meeting), so a duplicate should not
            -- exist; if one ever did, leaving half of it behind would show a
            -- stale value depending on list order.
            , test "replaces every row for that person and meeting" <|
                \_ ->
                    clicked "led" (stateWith [ absent, absent ])
                        |> saved "led"
                        |> allParticipationFor meetingSlug userID
                        |> Expect.equal [ "led", "led" ]
            , test "clears the pending entry" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> saved "led"
                        |> pendingFor meetingSlug userID
                        |> Expect.equal Nothing
            , test "sends nothing further" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> savedSending "led"
                        |> Expect.equal Nothing
            ]
        , describe "a failed save"
            [ test "does not change the stored value" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> failed
                        |> participationFor meetingSlug userID
                        |> Expect.equal (Just "absent")
            , test "is kept, naming the value that was lost" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> refused
                        |> pendingFor meetingSlug userID
                        |> Expect.equal (Just (SaveFailed "led"))
            , test "a later click retries rather than queueing behind nothing" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> failed
                        |> onChangeEngagement meetingSlug userID "attended"
                        |> Tuple.second
                        |> Expect.equal (Just "attended")
            ]

        -- A request that never answers used to strand the row: serialising
        -- means a later click only queues, so nothing would start another
        -- request and the row said "Saving…" until the page was reloaded. The
        -- request carries a timeout so that cannot happen; these cover what
        -- the row does with the answer, which is the part a test can see.
        , describe "a save that does not come back cleanly"
            [ test "a timeout is not reported as a refusal" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> timedOut
                        |> pendingFor meetingSlug userID
                        |> Expect.equal (Just (SaveUnknown "led"))
            , test "a lost connection is not reported as a refusal either" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> failed
                        |> pendingFor meetingSlug userID
                        |> Expect.equal (Just (SaveUnknown "led"))
            , test "a response the server refused is reported as one" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> refused
                        |> pendingFor meetingSlug userID
                        |> Expect.equal (Just (SaveFailed "led"))
            , test "a timeout leaves the row able to start another save" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> timedOut
                        |> onChangeEngagement meetingSlug userID "attended"
                        |> Tuple.second
                        |> Expect.equal (Just "attended")
            , test "and that save settles the row as usual" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> timedOut
                        |> clicked "attended"
                        |> saved "attended"
                        |> Expect.all
                            [ participationFor meetingSlug userID >> Expect.equal (Just "attended")
                            , pendingFor meetingSlug userID >> Expect.equal Nothing
                            ]
            ]

        -- Two requests in flight for one row cannot be reconciled afterwards:
        -- whichever answer the client keeps, it is guessing at what the server
        -- ended up holding. So a click during a save waits its turn.
        , describe "a click while a save is in flight"
            [ test "does not start a second request" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> onChangeEngagement meetingSlug userID "contributed"
                        |> Tuple.second
                        |> Expect.equal Nothing
            , test "is queued behind the one in flight" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> onChangeEngagement meetingSlug userID "contributed"
                        |> Tuple.first
                        |> pendingFor meetingSlug userID
                        |> Expect.equal (Just (Saving { inFlight = "led", queued = Just "contributed" }))
            , test "goes out once the row is free" <|
                \_ ->
                    twoClicks
                        |> savedSending "led"
                        |> Expect.equal (Just "contributed")
            , test "is not sent twice" <|
                \_ ->
                    twoClicks
                        |> saved "led"
                        |> pendingFor meetingSlug userID
                        |> Expect.equal (Just (Saving { inFlight = "contributed", queued = Nothing }))
            , test "is not sent at all if the server already holds it" <|
                \_ ->
                    clicked "led" (stateWith [ absent ])
                        |> onChangeEngagement meetingSlug userID "led"
                        |> Tuple.first
                        |> savedSending "led"
                        |> Expect.equal Nothing

            -- The first save succeeded, so the server holds "led". Discarding
            -- that success because a newer click existed left the page showing
            -- "absent" and telling the user it was what is recorded.
            , test "an earlier success is kept when the later save fails" <|
                \_ ->
                    twoClicks
                        |> saved "led"
                        |> failed
                        |> participationFor meetingSlug userID
                        |> Expect.equal (Just "led")
            , test "the row then reports the later value as the lost one" <|
                \_ ->
                    twoClicks
                        |> saved "led"
                        |> failed
                        |> pendingFor meetingSlug userID
                        |> Expect.equal (Just (SaveUnknown "contributed"))
            , test "an earlier failure gives way to the later click" <|
                \_ ->
                    twoClicks
                        |> failedSending
                        |> Expect.equal (Just "contributed")
            , test "and the later value is the one finally stored" <|
                \_ ->
                    twoClicks
                        |> failed
                        |> saved "contributed"
                        |> participationFor meetingSlug userID
                        |> Expect.equal (Just "contributed")
            ]

        -- A response can only ever belong to the one request outstanding for
        -- its row, so there is no number to reuse and no stale answer that can
        -- satisfy a newer pending entry.
        , describe "a third click after two are resolved"
            [ test "starts its own request" <|
                \_ ->
                    twoClicks
                        |> saved "led"
                        |> saved "contributed"
                        |> onChangeEngagement meetingSlug userID "attended"
                        |> Tuple.second
                        |> Expect.equal (Just "attended")
            , test "is still outstanding after the earlier saves are answered" <|
                \_ ->
                    thirdClick
                        |> pendingFor meetingSlug userID
                        |> Expect.equal (Just (Saving { inFlight = "attended", queued = Nothing }))
            , test "and it is its own answer that settles the row" <|
                \_ ->
                    thirdClick
                        |> saved "attended"
                        |> Expect.all
                            [ participationFor meetingSlug userID >> Expect.equal (Just "attended")
                            , pendingFor meetingSlug userID >> Expect.equal Nothing
                            ]
            ]
        ]



-- Fixtures and helpers


type alias State =
    { engagements : WebData (List Engagement)
    , pendingSubmitEngagements : Dict ( String, Int ) PendingSubmit
    }


stateWith : List Engagement -> State
stateWith engagements =
    { engagements = RemoteData.Success engagements, pendingSubmitEngagements = Dict.empty }


clicked : String -> State -> State
clicked participation state =
    onChangeEngagement meetingSlug userID participation state |> Tuple.first


{-| "led" is in flight, "contributed" is queued behind it.
-}
twoClicks : State
twoClicks =
    stateWith [ absent ] |> clicked "led" |> clicked "contributed"


{-| Both earlier saves answered, then a fresh click.
-}
thirdClick : State
thirdClick =
    twoClicks |> saved "led" |> saved "contributed" |> clicked "attended"


saved : String -> State -> State
saved participation state =
    onSubmitEngagementResponse meetingSlug userID (RemoteData.Success (engagementAs participation)) state
        |> Tuple.first


{-| What the handler asks to be sent next once a save comes back.
-}
savedSending : String -> State -> Maybe String
savedSending participation state =
    onSubmitEngagementResponse meetingSlug userID (RemoteData.Success (engagementAs participation)) state
        |> Tuple.second


failed : State -> State
failed state =
    respondingWith (RemoteData.Failure Http.NetworkError) state


{-| The server answered and refused the write, so it certainly did not land.
-}
refused : State -> State
refused state =
    respondingWith (RemoteData.Failure (Http.BadStatus 403)) state


timedOut : State -> State
timedOut state =
    respondingWith (RemoteData.Failure Http.Timeout) state


respondingWith : WebData Engagement -> State -> State
respondingWith response state =
    onSubmitEngagementResponse meetingSlug userID response state
        |> Tuple.first


failedSending : State -> Maybe String
failedSending state =
    onSubmitEngagementResponse meetingSlug userID (RemoteData.Failure Http.NetworkError) state
        |> Tuple.second


participationFor : String -> Int -> EngagementState a -> Maybe String
participationFor slug uid state =
    allParticipationFor slug uid state |> List.head


allParticipationFor : String -> Int -> EngagementState a -> List String
allParticipationFor slug uid state =
    state.engagements
        |> RemoteData.withDefault []
        |> List.filter (\e -> e.meeting_slug == slug && e.user_id == uid)
        |> List.map .participation


engagementCount : EngagementState a -> Int
engagementCount state =
    state.engagements |> RemoteData.withDefault [] |> List.length


pendingFor : String -> Int -> EngagementState a -> Maybe PendingSubmit
pendingFor slug uid state =
    Dict.get ( slug, uid ) state.pendingSubmitEngagements


meetingSlug : String
meetingSlug =
    "class-01"


otherMeetingSlug : String
otherMeetingSlug =
    "class-02"


userID : Int
userID =
    42


absent : Engagement
absent =
    { user_id = userID
    , meeting_slug = meetingSlug
    , participation = "absent"
    , created_at = Time.millisToPosix 0
    , updated_at = Time.millisToPosix 0
    }


{-| What the server sends back: the saved row, with its own updated\_at.
-}
engagementAs : String -> Engagement
engagementAs participation =
    { absent | participation = participation, updated_at = Time.millisToPosix 1000 }


otherStudent : Engagement
otherStudent =
    { absent | user_id = 43, participation = "attended" }


sameStudentOtherMeeting : Engagement
sameStudentOtherMeeting =
    { absent | meeting_slug = otherMeetingSlug, participation = "contributed" }
