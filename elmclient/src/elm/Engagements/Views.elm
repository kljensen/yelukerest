module Engagements.Views exposing (PendingSubmits, maybeEditEngagements)

import Auth.Model exposing (CurrentUser, isFacultyOrTA)
import Auth.Views exposing (loginLink)
import Dict exposing (Dict)
import Engagements.Model exposing (Engagement, PendingSubmit(..), participationEnum)
import Html exposing (Html)
import Html.Attributes as Attrs
import Html.Events as Events
import Meetings.Model exposing (Meeting)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Users.Model exposing (User, niceName)


{-| The in-flight (and failed) saves, keyed by meeting slug and user id, as
`Models.pendingSubmitEngagements` holds them.
-}
type alias PendingSubmits =
    Dict ( String, Int ) PendingSubmit


type alias EngagementData =
    { users : List User
    , engagements : List Engagement
    , meetings : List Meeting
    }


makeEngagementData : List User -> List Engagement -> List Meeting -> EngagementData
makeEngagementData users engagements meetings =
    { users = users
    , engagements = engagements
    , meetings = meetings
    }


mergeEngagementData : WebData (List User) -> WebData (List Engagement) -> WebData (List Meeting) -> WebData EngagementData
mergeEngagementData wdUsers wdEngagements wdMeetings =
    RemoteData.map makeEngagementData wdUsers
        |> RemoteData.andMap wdEngagements
        |> RemoteData.andMap wdMeetings


maybeEditEngagements : WebData CurrentUser -> Maybe String -> WebData (List User) -> WebData (List Engagement) -> WebData (List Meeting) -> PendingSubmits -> String -> Html.Html Msg
maybeEditEngagements wdCurrentUser userQuery wdUsers wdEngagements wdMeetings pendingSubmits meetingSlug =
    case wdCurrentUser of
        -- The roster and engagement requests are only issued once we know who
        -- is signed in, so without a session the data below can never leave
        -- Loading. Ask for a login instead of spinning forever.
        RemoteData.NotAsked ->
            mustLogIn

        RemoteData.Failure _ ->
            mustLogIn

        RemoteData.Loading ->
            Html.text "Loading..."

        RemoteData.Success currentUser ->
            if isFacultyOrTA currentUser.role then
                case mergeEngagementData wdUsers wdEngagements wdMeetings of
                    RemoteData.Success data ->
                        editEngagements userQuery data pendingSubmits meetingSlug

                    RemoteData.Loading ->
                        Html.text "Loading..."

                    RemoteData.NotAsked ->
                        Html.text "Loading..."

                    RemoteData.Failure _ ->
                        Html.div [ Attrs.class "error" ]
                            [ Html.text "Could not load the roster for this meeting. Reload the page, or "
                            , loginLink
                            , Html.text " again if your session has expired."
                            ]

            else
                Html.text "forbidden"


mustLogIn : Html.Html Msg
mustLogIn =
    Html.div []
        [ Html.text "You must be signed in as faculty or a TA to take attendance. "
        , loginLink
        , Html.text "."
        ]


editEngagements : Maybe String -> EngagementData -> PendingSubmits -> String -> Html.Html Msg
editEngagements userQuery data pendingSubmits meetingSlug =
    let
        maybeMeeting =
            data.meetings
                |> List.filter (\meeting -> meeting.slug == meetingSlug)
                |> List.head
    in
    case maybeMeeting of
        Just meeting ->
            editEngagementsForMeeting userQuery data pendingSubmits meeting

        Nothing ->
            Html.text "No such meeting"


editEngagementsForMeeting : Maybe String -> EngagementData -> PendingSubmits -> Meeting -> Html.Html Msg
editEngagementsForMeeting userQuery data pendingSubmits meeting =
    let
        renderUser =
            userEngagementSelect meeting.slug data.engagements pendingSubmits

        matchingUsers =
            searchStudents data.users userQuery

        queryValue =
            case userQuery of
                Nothing ->
                    ""

                Just q ->
                    q
    in
    Html.div [ Attrs.class "engagement-student-holder" ]
        [ Html.h1 [] [ Html.text ("Attendance — " ++ meeting.title) ]
        , Html.input
            [ Events.onInput Msgs.OnChangeEngagementUserQuery
            , Attrs.class "engagement-user-query"
            , Attrs.placeholder
                "🔎 Search..."
            , Attrs.value queryValue
            ]
            []
        , Html.div [] (List.map renderUser matchingUsers)
        ]


{-| The people whose attendance can be taken.

`users` is everyone with an account. The role enum also holds faculty, ta and
observer, and the database counts a cohort the same way this does (see the
`role = 'student'` filters in the grade distribution views), so this names the
role that is enrolled rather than excluding the ones that are not: excluding
faculty and TAs still left observers on the roster.

-}
searchStudents : List User -> Maybe String -> List User
searchStudents users userQuery =
    let
        students =
            List.filter (\user -> user.role == "student") users
    in
    case userQuery of
        Nothing ->
            students

        Just q ->
            List.filter (userMatchesQuery q) students


userMatchesQuery : String -> User -> Bool
userMatchesQuery userQuery user =
    [ user.name, user.known_as ]
        |> List.map (stringMatches userQuery)
        |> List.any (\x -> x == True)


stringMatches : String -> Maybe String -> Bool
stringMatches x y =
    case y of
        Just z ->
            String.toLower z
                |> String.contains (String.toLower x)

        Nothing ->
            False


{-| The option to show as chosen.

While a save is in flight this is the value that was clicked most recently,
and once it fails it is the recorded value again. That swap is the whole
point: clicking a radio mutates the DOM behind Elm's back, so a failed save
would leave the control showing an option that was never stored. Elm only
rewrites `checked` when its own view of it changes, and moving the highlight
onto the attempted value on the way out is what gives it something to change
back.

Once a save has stopped, this falls back to the last value the server
confirmed. That is the best the page knows; it is not a claim about what is
stored now, which is why the message beside it no longer makes one.

-}
isSaving : Maybe PendingSubmit -> Bool
isSaving pending =
    case pending of
        Just (Saving _) ->
            True

        _ ->
            False


{-| A save that stopped without settling the row, whether it was refused or
simply never confirmed. Both need the row to stand out from a saved one.
-}
saveDidNotComplete : Maybe PendingSubmit -> Bool
saveDidNotComplete pending =
    case pending of
        Just (SaveFailed _) ->
            True

        Just (SaveUnknown _) ->
            True

        _ ->
            False


chosenParticipation : Maybe Engagement -> Maybe PendingSubmit -> Maybe String
chosenParticipation maybeEngagement pending =
    case pending of
        Just (Saving saving) ->
            Just (Maybe.withDefault saving.inFlight saving.queued)

        _ ->
            Maybe.map .participation maybeEngagement


{-| A word about the save, so an unfinished or lost one is not silent.

A failure especially needs saying: the browser has already moved the radio to
the option that was clicked, but nothing was recorded, so the row would
otherwise look exactly like a saved one.

Neither message says what is recorded. Any save that does not come back
cleanly leaves that in doubt — and even a refusal tells us nothing about a
student who had no engagement to fall back to, where there is no highlight to
point at. Naming the value that did not go through is both true and enough to
act on.

-}
saveStatus : Maybe PendingSubmit -> Html.Html Msg
saveStatus pending =
    case pending of
        Nothing ->
            Html.text ""

        Just (Saving _) ->
            Html.span [ Attrs.class "engagement-status" ] [ Html.text "Saving…" ]

        Just (SaveFailed attempted) ->
            Html.span [ Attrs.class "engagement-status" ]
                [ Html.text ("Not saved: " ++ attempted ++ " — try again.") ]

        Just (SaveUnknown attempted) ->
            Html.span [ Attrs.class "engagement-status" ]
                [ Html.text ("Could not confirm: " ++ attempted ++ ". Reload to see what is recorded.") ]


userEngagementSelect : String -> List Engagement -> PendingSubmits -> User -> Html.Html Msg
userEngagementSelect meetingSlug engagements pendingSubmits user =
    let
        maybeEngagement =
            engagements
                |> List.filter (\e -> e.user_id == user.id && e.meeting_slug == meetingSlug)
                |> List.head

        pending =
            Dict.get ( meetingSlug, user.id ) pendingSubmits

        chosen =
            chosenParticipation maybeEngagement pending

        renderOptions =
            participationSelectOption maybeEngagement

        onInputHandler =
            Msgs.OnChangeEngagement meetingSlug user.id
    in
    Html.div
        [ Attrs.classList
            [ ( "student", True )
            , ( "saving", isSaving pending )
            , ( "save-failed", saveDidNotComplete pending )
            ]
        ]
        [ Html.span [] [ Html.text (niceName user) ]
        , saveStatus pending
        , Html.div
            [ Attrs.class "radio-holder"
            , Events.onInput onInputHandler
            ]
            (List.map (participationRadioOption user.id chosen) participationEnum)

        -- We used to use select. Keeping here for now...
        -- , Html.select
        --     [ Events.onInput onInputHandler, Attrs.name (String.fromInt user.id), Attrs.class "engagement" ]
        --     (List.map renderOptions participationEnum)
        ]


participationSelectOption : Maybe Engagement -> String -> Html.Html Msg
participationSelectOption maybeEngagement optionValue =
    let
        isSelected =
            case maybeEngagement of
                Nothing ->
                    False

                Just engagement ->
                    engagement.participation == optionValue
    in
    Html.option
        [ Attrs.value optionValue
        , Attrs.selected isSelected
        ]
        [ Html.text optionValue ]


participationRadioOption : Int -> Maybe String -> String -> Html.Html Msg
participationRadioOption userId chosen optionValue =
    let
        isSelected =
            chosen == Just optionValue
    in
    Html.label
        [ Attrs.classList
            [ ( "selected", isSelected ) ]
        ]
        [ Html.input
            [ Attrs.value optionValue
            , Attrs.checked isSelected
            , Attrs.type_ "radio"
            , Attrs.name ("user-" ++ String.fromInt userId ++ "-engagement")
            ]
            []
        , Html.text optionValue
        ]
