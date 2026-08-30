module EngagementsViewsTest exposing (tests)

import Auth.Model exposing (CurrentUser)
import Dict
import Engagements.Model exposing (Engagement, PendingSubmit(..))
import Engagements.Views exposing (PendingSubmits, maybeEditEngagements)
import Expect
import Html.Attributes as Attrs
import Http
import Meetings.Model exposing (Meeting)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Time
import Users.Model exposing (User)


tests : Test
tests =
    describe "Engagements.Views.maybeEditEngagements"
        [ describe "the roster"
            -- Attendance is taken for the enrolled students. The user list also
            -- holds faculty, TAs and observers, none of whom can be marked
            -- absent; listing them offered more rows than there are people
            -- enrolled.
            [ test "lists one row per student" <|
                \_ ->
                    signedInView Dict.empty
                        |> Query.findAll [ Selector.class "student" ]
                        |> Query.count (Expect.equal 2)
            , test "does not name the instructor" <|
                \_ ->
                    signedInView Dict.empty
                        |> Query.hasNot [ Selector.text "Prof Plum" ]
            , test "does not name the TA" <|
                \_ ->
                    signedInView Dict.empty
                        |> Query.hasNot [ Selector.text "Miss Scarlett" ]
            , test "does not name an observer" <|
                \_ ->
                    signedInView Dict.empty
                        |> Query.hasNot [ Selector.text "Colonel Mustard" ]
            ]
        , describe "a save in flight"
            [ test "says so on that student's row" <|
                \_ ->
                    signedInView (saving "led")
                        |> Query.find [ Selector.class "saving" ]
                        |> Query.has [ Selector.text ada.nickname, Selector.text "Saving…" ]
            , test "marks only that student's row" <|
                \_ ->
                    signedInView (saving "led")
                        |> Query.findAll [ Selector.class "saving" ]
                        |> Query.count (Expect.equal 1)

            -- The clicked option is shown as chosen while the request is out.
            -- This is not cosmetic: the browser has already moved the radio,
            -- and Elm will only move it back if its own view of `checked`
            -- changes. Showing the attempt here is what gives the rollback
            -- below something to undo.
            , test "shows the clicked option as chosen" <|
                \_ ->
                    signedInView (saving "led")
                        |> rowFor ada
                        |> expectChosen "led"
            , test "shows the most recent click, not the one being written" <|
                \_ ->
                    signedInView (savingWithQueued "led" "contributed")
                        |> rowFor ada
                        |> expectChosen "contributed"
            ]
        , describe "a failed save"
            [ test "is visibly distinguishable from a saved one" <|
                \_ ->
                    signedInView (saveFailed "led")
                        |> Query.findAll [ Selector.class "save-failed" ]
                        |> Query.count (Expect.equal 1)
            , test "says on that student's row that nothing was recorded" <|
                \_ ->
                    signedInView (saveFailed "led")
                        |> Query.find [ Selector.class "save-failed" ]
                        |> Query.has
                            [ Selector.text ada.nickname
                            , Selector.text "Not saved: led — try again."
                            ]
            , test "puts the recorded option back as the chosen one" <|
                \_ ->
                    signedInView (saveFailed "led")
                        |> rowFor ada
                        |> expectChosen adaIsAbsent.participation
            , test "highlights the recorded option" <|
                \_ ->
                    signedInView (saveFailed "led")
                        |> Query.find [ Selector.class "save-failed" ]
                        |> Query.find [ Selector.class "selected" ]
                        |> Query.has [ Selector.text adaIsAbsent.participation ]

            -- Grace has nothing recorded, so there is no highlight. A
            -- message claiming the highlighted option is what is stored was
            -- simply false here, and any save that does not come back cleanly
            -- leaves what is stored in doubt anyway.
            , test "does not claim what is recorded for a student with no engagement" <|
                \_ ->
                    signedInView graceSaveFailed
                        |> rowFor grace
                        |> Query.has [ Selector.text "Not saved: led — try again." ]
            , test "and highlights nothing for her, having nothing to highlight" <|
                \_ ->
                    signedInView graceSaveFailed
                        |> rowFor grace
                        |> Query.findAll [ Selector.checked True ]
                        |> Query.count (Expect.equal 0)
            , test "leaves the other student's row alone" <|
                \_ ->
                    signedInView (saveFailed "led")
                        |> Query.findAll [ Selector.class "engagement-status" ]
                        |> Query.count (Expect.equal 1)
            ]
        , describe "a save that never came back cleanly"
            [ test "says the outcome is unknown rather than asserting one" <|
                \_ ->
                    signedInView (saveUnknown "led")
                        |> rowFor ada
                        |> Query.has
                            [ Selector.text "Could not confirm: led. Reload to see what is recorded." ]
            , test "stands out from a saved row" <|
                \_ ->
                    signedInView (saveUnknown "led")
                        |> Query.findAll [ Selector.class "save-failed" ]
                        |> Query.count (Expect.equal 1)
            ]
        , describe "a settled row"
            [ test "says nothing about saving" <|
                \_ ->
                    signedInView Dict.empty
                        |> Query.hasNot [ Selector.class "engagement-status" ]
            , test "shows the recorded option as chosen" <|
                \_ ->
                    signedInView Dict.empty
                        |> rowFor ada
                        |> expectChosen adaIsAbsent.participation
            , test "shows nothing as chosen for a student with no engagement" <|
                \_ ->
                    signedInView Dict.empty
                        |> rowFor grace
                        |> Query.findAll [ Selector.checked True ]
                        |> Query.count (Expect.equal 0)
            ]

        -- Signed out, /auth/me fails and the roster is never requested, so the
        -- page can only ever wait. It has to say what is wrong instead.
        , describe "signed out"
            [ test "the visitor is offered a login" <|
                \_ ->
                    signedOutView
                        |> Query.has [ Selector.attribute (Attrs.href "/auth/login") ]
            , test "the visitor is not told the page is loading" <|
                \_ ->
                    signedOutView
                        |> Query.hasNot [ Selector.text "Loading..." ]
            ]
        ]



-- Fixtures and helpers


{-| One student's row, found by name rather than by position.
-}
rowFor : User -> Query.Single Msg -> Query.Single Msg
rowFor user view =
    Query.find [ Selector.class "student", Selector.containing [ Selector.text user.nickname ] ] view


{-| The option that row shows as chosen. `find` also asserts there is exactly
one, which is what a radio group means.
-}
expectChosen : String -> Query.Single Msg -> Expect.Expectation
expectChosen option row =
    row
        |> Query.find [ Selector.checked True ]
        |> Query.has [ Selector.attribute (Attrs.value option) ]


signedInView : PendingSubmits -> Query.Single Msg
signedInView pendingSubmits =
    maybeEditEngagements
        (RemoteData.Success plum)
        Nothing
        (RemoteData.Success [ plumUser, ta, observer, ada, grace ])
        (RemoteData.Success [ adaIsAbsent ])
        (RemoteData.Success [ meeting ])
        pendingSubmits
        meeting.slug
        |> Query.fromHtml


signedOutView : Query.Single Msg
signedOutView =
    maybeEditEngagements
        (RemoteData.Failure (Http.BadStatus 401))
        Nothing
        RemoteData.NotAsked
        RemoteData.NotAsked
        RemoteData.NotAsked
        Dict.empty
        meeting.slug
        |> Query.fromHtml


{-| Ada has clicked `participation` and the save is still out.
-}
saving : String -> PendingSubmits
saving participation =
    Dict.singleton ( meeting.slug, ada.id )
        (Saving { inFlight = participation, queued = Nothing })


{-| Ada clicked `participation` while a save was already out, so it is waiting
its turn behind the one in flight.
-}
savingWithQueued : String -> String -> PendingSubmits
savingWithQueued inFlight queued =
    Dict.singleton ( meeting.slug, ada.id )
        (Saving { inFlight = inFlight, queued = Just queued })


{-| Ada's click was refused, so it certainly was not stored.
-}
saveFailed : String -> PendingSubmits
saveFailed participation =
    Dict.singleton ( meeting.slug, ada.id ) (SaveFailed participation)


{-| Ada's save never came back cleanly, so what the server holds is unknown.
-}
saveUnknown : String -> PendingSubmits
saveUnknown participation =
    Dict.singleton ( meeting.slug, ada.id ) (SaveUnknown participation)


{-| Grace has no engagement recorded at all, and her first save was refused:
there is no highlighted option for a message to point at.
-}
graceSaveFailed : PendingSubmits
graceSaveFailed =
    Dict.singleton ( meeting.slug, grace.id ) (SaveFailed "led")


meeting : Meeting
meeting =
    { slug = "class-01"
    , title = "First class"
    , summary = Nothing
    , description = ""
    , begins_at = Time.millisToPosix 0
    , meeting_type = "lecture"
    , is_draft = False
    }


plum : CurrentUser
plum =
    { id = 1
    , netid = "plum"
    , jwt = "jwt"
    , role = "faculty"
    , nickname = "plum"
    , team_nickname = Nothing
    }


baseUser : User
baseUser =
    { id = 1
    , netid = "plum"
    , role = "faculty"
    , email = Nothing
    , name = Just "Prof Plum"
    , known_as = Nothing
    , nickname = "Prof Plum"
    , team_nickname = Nothing
    }


plumUser : User
plumUser =
    baseUser


ta : User
ta =
    { baseUser | id = 2, netid = "scarlett", role = "ta", name = Just "Miss Scarlett", nickname = "Miss Scarlett" }


{-| Observers are read-only guests on the course. They are neither faculty nor
TAs, so a roster filter written as "not faculty or TA" still lists them.
-}
observer : User
observer =
    { baseUser | id = 5, netid = "mustard", role = "observer", name = Just "Colonel Mustard", nickname = "Colonel Mustard" }


ada : User
ada =
    { baseUser | id = 3, netid = "ada", role = "student", name = Just "Ada Lovelace", nickname = "Ada Lovelace" }


grace : User
grace =
    { baseUser | id = 4, netid = "grace", role = "student", name = Just "Grace Hopper", nickname = "Grace Hopper" }


adaIsAbsent : Engagement
adaIsAbsent =
    { user_id = ada.id
    , meeting_slug = meeting.slug
    , participation = "absent"
    , created_at = Time.millisToPosix 0
    , updated_at = Time.millisToPosix 0
    }
