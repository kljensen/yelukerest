module Engagements.Model exposing
    ( Engagement
    , PendingSubmit(..)
    , engagementDecoder
    , engagementsDecoder
    , failureFor
    , participationEnum
    , upsertEngagement
    )

import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Decode.Extra exposing (datetime)
import Json.Decode.Pipeline exposing (required)
import Time exposing (Posix)


type alias Engagement =
    { user_id : Int
    , meeting_slug : String
    , participation : String
    , created_at : Posix
    , updated_at : Posix
    }


{-| The unfinished business on one person's attendance.

Saves for a row are serialised: at most one request is in flight for it, and a
click made while that request is out is held in `queued` rather than starting a
second one. Two requests racing for the same row cannot be reconciled by the
client — whichever answer it decides to keep, it is guessing at what the server
ended up holding — and that guess is the same failure as the original bug: the
page asserting a value the server does not have.

Serialising buys two things. A success is always the most recent write, so
merging it is unconditionally right. And once every success is merged, the
recorded value really is what the highlight shows, so the row can say so after
a failure without lying.

`Saving.inFlight` is the value being written; `queued` is a later click waiting
its turn. The two settled-badly states carry the value that was clicked, which
is what the row needs to name.

-}
type PendingSubmit
    = Saving { inFlight : String, queued : Maybe String }
    | SaveFailed String
    | SaveUnknown String


{-| How to describe a save that did not come back cleanly.

Only a refusal tells us the write did not land: the upsert is one statement in
one transaction, so a non-2xx status means nothing was committed. A timeout or
a lost connection leaves the outcome genuinely unknown, and a response we
cannot decode means it landed but we cannot read what it landed as. Neither is
worth chasing down for one person clicking radio buttons, so the row says it
does not know and points at the reload that would settle it.

-}
failureFor : Http.Error -> String -> PendingSubmit
failureFor error attempted =
    case error of
        Http.BadStatus _ ->
            SaveFailed attempted

        _ ->
            SaveUnknown attempted


participationEnum : List String
participationEnum =
    [ "absent", "attended", "contributed", "led" ]


engagementsDecoder : Decode.Decoder (List Engagement)
engagementsDecoder =
    Decode.list engagementDecoder


engagementDecoder : Decode.Decoder Engagement
engagementDecoder =
    Decode.succeed Engagement
        |> required "user_id" Decode.int
        |> required "meeting_slug" Decode.string
        |> required "participation" Decode.string
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime


{-| Put a saved engagement in place of the one already recorded for that
person and meeting, adding it if they had none.

There is at most one engagement per (user, meeting) — the server upserts on
that pair — so replacing every match is the same as replacing the one match.

-}
upsertEngagement : Engagement -> List Engagement -> List Engagement
upsertEngagement engagement engagements =
    let
        isSamePerson e =
            e.user_id == engagement.user_id && e.meeting_slug == engagement.meeting_slug
    in
    if List.any isSamePerson engagements then
        List.map
            (\e ->
                if isSamePerson e then
                    engagement

                else
                    e
            )
            engagements

    else
        engagement :: engagements
