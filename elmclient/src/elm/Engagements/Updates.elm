module Engagements.Updates exposing
    ( EngagementState
    , onChangeEngagement
    , onSubmitEngagementResponse
    )

import Dict exposing (Dict)
import Engagements.Model exposing (Engagement, PendingSubmit(..), failureFor, upsertEngagement)
import RemoteData exposing (WebData)


{-| The slice of the model that recording attendance touches.

This is an extensible record rather than `Models.Model` (as the sibling
`Assignments.Updates` uses) because the full model holds a
`Browser.Navigation.Key`, which no test can construct. Naming only the two
fields involved lets the tests drive these transitions directly.

-}
type alias EngagementState a =
    { a
        | engagements : WebData (List Engagement)
        , pendingSubmitEngagements : Dict ( String, Int ) PendingSubmit
    }


{-| Both handlers return the participation to send for this row now, if any.
Building the request needs the signed-in user's JWT, which this module has no
business knowing; `Update` turns it into a command.
-}
type alias Outcome a =
    ( EngagementState a, Maybe String )


{-| A click on one student's row.

While a request is out the click is queued rather than sent. That is what keeps
one request in flight per row — see `Engagements.Model.PendingSubmit` for why
racing two is not something the client can straighten out afterwards.

-}
onChangeEngagement : String -> Int -> String -> EngagementState a -> Outcome a
onChangeEngagement meetingSlug userID participation state =
    let
        key =
            ( meetingSlug, userID )
    in
    case Dict.get key state.pendingSubmitEngagements of
        Just (Saving saving) ->
            ( setPending key (Saving { saving | queued = Just participation }) state
            , Nothing
            )

        _ ->
            ( startSaving key participation state, Just participation )


{-| The outcome of one attendance save.

The saved row goes into `engagements`, which is what the view reads to decide
which option is highlighted. Without that, the page keeps showing the previous
value until a full reload, so a faculty member taking attendance sees the page
silently disagree with what is stored.

The row merged in is the one the server returned (`submitEngagement` asks for
it with `Prefer: return=representation`) rather than one built here: the server
owns `updated_at`, and it may store something other than what was sent.

A queued click goes out now that the row is free. After a failure it replaces
the failure outright: the person has already asked for something newer, and
reporting an abandoned value as unsaved would be noise.

-}
onSubmitEngagementResponse : String -> Int -> WebData Engagement -> EngagementState a -> Outcome a
onSubmitEngagementResponse meetingSlug userID response state =
    let
        key =
            ( meetingSlug, userID )
    in
    case ( Dict.get key state.pendingSubmitEngagements, response ) of
        ( Just (Saving saving), RemoteData.Success engagement ) ->
            let
                merged =
                    mergeSaved engagement state
            in
            case saving.queued of
                -- Sending it again would write what the server already holds.
                Just queued ->
                    if queued == engagement.participation then
                        ( clearPending key merged, Nothing )

                    else
                        ( startSaving key queued merged, Just queued )

                Nothing ->
                    ( clearPending key merged, Nothing )

        ( Just (Saving saving), RemoteData.Failure error ) ->
            case saving.queued of
                Just queued ->
                    ( startSaving key queued state, Just queued )

                Nothing ->
                    ( setPending key (failureFor error saving.inFlight) state, Nothing )

        ( _, RemoteData.Success engagement ) ->
            -- No request was outstanding for this row, which serialised saves
            -- should make unreachable. The server has still told us what it
            -- holds, and recording that can only make the page more truthful.
            ( mergeSaved engagement state, Nothing )

        _ ->
            ( state, Nothing )


mergeSaved : Engagement -> EngagementState a -> EngagementState a
mergeSaved engagement state =
    { state | engagements = RemoteData.map (upsertEngagement engagement) state.engagements }


startSaving : ( String, Int ) -> String -> EngagementState a -> EngagementState a
startSaving key participation state =
    setPending key (Saving { inFlight = participation, queued = Nothing }) state


setPending : ( String, Int ) -> PendingSubmit -> EngagementState a -> EngagementState a
setPending key pending state =
    { state | pendingSubmitEngagements = Dict.insert key pending state.pendingSubmitEngagements }


clearPending : ( String, Int ) -> EngagementState a -> EngagementState a
clearPending key state =
    { state | pendingSubmitEngagements = Dict.remove key state.pendingSubmitEngagements }
