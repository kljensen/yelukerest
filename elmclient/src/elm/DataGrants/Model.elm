module DataGrants.Model exposing
    ( ApiGrant
    , CreatedGrant
    , DraftAssignment
    , GrantDraft
    , GrantPermission
    , addDraftAssignment
    , allIdentities
    , apiGrantsDecoder
    , createGrantBody
    , createdGrantDecoder
    , draftIsComplete
    , emptyDraft
    , isoDate
    , permissionText
    , removeDraftAssignment
    , setDraftAssignmentSlug
    , setDraftExpiry
    , setDraftField
    , setDraftIdentity
    , setDraftName
    )

import DateFormat
import Json.Decode as Decode
import Json.Decode.Pipeline exposing (optional, required)
import Json.Encode as Encode
import Set exposing (Set)
import Time exposing (Posix, Zone)


{-| One grant as `api.api_grants` reports it: what a consuming app may read,
and its lifecycle. There is no credential here; none is stored (ADR 0005).
-}
type alias ApiGrant =
    { id : Int
    , name : String
    , createdBy : Int
    , createdAt : String
    , expiresAt : String
    , revokedBy : Maybe Int
    , revokedAt : Maybe String
    , isActive : Bool
    , permissions : List GrantPermission
    }


{-| What the grant may read of one assignment. `identity` is any subset of
`allIdentities`, possibly none; `fieldSlugs` is never empty.
-}
type alias GrantPermission =
    { assignmentSlug : String
    , identity : List String
    , fieldSlugs : List String
    }


{-| The one-time response from `api.create_api_grant`. `token` is never
obtainable again.
-}
type alias CreatedGrant =
    { id : Int
    , token : String
    , expiresAt : String
    }


{-| The form. `expiresAt` is a `YYYY-MM-DD` date; `Nothing` leaves the choice
to the server, whose default is 90 days from now.
-}
type alias GrantDraft =
    { name : String
    , expiresAt : Maybe String
    , assignments : List DraftAssignment
    }


type alias DraftAssignment =
    { assignmentSlug : String
    , identity : Set String
    , fieldSlugs : Set String
    }


{-| The identity vocabulary `data.api_grant_assignment` accepts, in the order
the form shows it.
-}
allIdentities : List String
allIdentities =
    [ "netid", "name", "nickname", "team_nickname" ]


emptyDraft : GrantDraft
emptyDraft =
    { name = "", expiresAt = Nothing, assignments = [ emptyDraftAssignment ] }


emptyDraftAssignment : DraftAssignment
emptyDraftAssignment =
    { assignmentSlug = "", identity = Set.empty, fieldSlugs = Set.empty }


setDraftName : String -> GrantDraft -> GrantDraft
setDraftName name draft =
    { draft | name = name }


{-| A cleared date input reports "", which means "the server's default"
rather than an empty string sent as a timestamp.
-}
setDraftExpiry : String -> GrantDraft -> GrantDraft
setDraftExpiry date draft =
    { draft
        | expiresAt =
            if date == "" then
                Nothing

            else
                Just date
    }


addDraftAssignment : GrantDraft -> GrantDraft
addDraftAssignment draft =
    { draft | assignments = draft.assignments ++ [ emptyDraftAssignment ] }


removeDraftAssignment : Int -> GrantDraft -> GrantDraft
removeDraftAssignment index draft =
    { draft | assignments = List.take index draft.assignments ++ List.drop (index + 1) draft.assignments }


{-| Choosing an assignment clears the fields: a field is a field OF an
assignment, and `url` on one is not `url` on another (ADR 0005).
-}
setDraftAssignmentSlug : Int -> String -> GrantDraft -> GrantDraft
setDraftAssignmentSlug index slug =
    updateDraftAssignment index (\row -> { row | assignmentSlug = slug, fieldSlugs = Set.empty })


setDraftIdentity : Int -> String -> Bool -> GrantDraft -> GrantDraft
setDraftIdentity index attribute isChecked =
    updateDraftAssignment index (\row -> { row | identity = toggle attribute isChecked row.identity })


setDraftField : Int -> String -> Bool -> GrantDraft -> GrantDraft
setDraftField index fieldSlug isChecked =
    updateDraftAssignment index (\row -> { row | fieldSlugs = toggle fieldSlug isChecked row.fieldSlugs })


updateDraftAssignment : Int -> (DraftAssignment -> DraftAssignment) -> GrantDraft -> GrantDraft
updateDraftAssignment index f draft =
    { draft
        | assignments =
            List.indexedMap
                (\i row ->
                    if i == index then
                        f row

                    else
                        row
                )
                draft.assignments
    }


toggle : comparable -> Bool -> Set comparable -> Set comparable
toggle item isChecked set =
    if isChecked then
        Set.insert item set

    else
        Set.remove item set


{-| The client-side half of what `data.create_api_grant_rows` checks: a name of
at least three characters and every assignment row chosen with at least one
field. The server still has the last word on everything, including the name's
upper bound, expiry and duplicates.
-}
draftIsComplete : GrantDraft -> Bool
draftIsComplete draft =
    String.length (String.trim draft.name)
        >= 3
        && not (List.isEmpty draft.assignments)
        && List.all (\row -> row.assignmentSlug /= "" && not (Set.isEmpty row.fieldSlugs)) draft.assignments


{-| The body of `POST /rest/rpc/create_api_grant`. `p_expires_at` is omitted
when the form left it blank, so the server applies its own 90-day default
rather than the client guessing the same number.
-}
createGrantBody : GrantDraft -> Encode.Value
createGrantBody draft =
    Encode.object
        ([ ( "p_name", Encode.string (String.trim draft.name) )
         , ( "p_assignments", Encode.list encodeDraftAssignment draft.assignments )
         ]
            ++ (case draft.expiresAt of
                    Just date ->
                        [ ( "p_expires_at", Encode.string date ) ]

                    Nothing ->
                        []
               )
        )


encodeDraftAssignment : DraftAssignment -> Encode.Value
encodeDraftAssignment row =
    Encode.object
        [ ( "assignment_slug", Encode.string row.assignmentSlug )

        -- Vocabulary order rather than Set order, so the stored permission
        -- reads the way the form did.
        , ( "identity", Encode.list Encode.string (List.filter (\a -> Set.member a row.identity) allIdentities) )
        , ( "field_slugs", Encode.list Encode.string (Set.toList row.fieldSlugs) )
        ]


{-| One permission as a line of plain text, for the listing:
`tacky-website: netid, name; fields: url`.
-}
permissionText : GrantPermission -> String
permissionText permission =
    let
        identity =
            if List.isEmpty permission.identity then
                "no identity"

            else
                String.join ", " permission.identity
    in
    permission.assignmentSlug ++ ": " ++ identity ++ "; fields: " ++ String.join ", " permission.fieldSlugs


{-| `YYYY-MM-DD`, the value an `<input type="date">` takes.
-}
isoDate : Zone -> Posix -> String
isoDate =
    DateFormat.format
        [ DateFormat.yearNumber
        , DateFormat.text "-"
        , DateFormat.monthFixed
        , DateFormat.text "-"
        , DateFormat.dayOfMonthFixed
        ]


apiGrantsDecoder : Decode.Decoder (List ApiGrant)
apiGrantsDecoder =
    Decode.list apiGrantDecoder


apiGrantDecoder : Decode.Decoder ApiGrant
apiGrantDecoder =
    Decode.succeed ApiGrant
        |> required "id" Decode.int
        |> required "name" Decode.string
        |> required "created_by" Decode.int
        |> required "created_at" Decode.string
        |> required "expires_at" Decode.string
        |> optional "revoked_by" (Decode.nullable Decode.int) Nothing
        |> optional "revoked_at" (Decode.nullable Decode.string) Nothing
        |> optional "is_active" Decode.bool False
        |> optional "permissions" (Decode.oneOf [ Decode.list permissionDecoder, Decode.null [] ]) []


permissionDecoder : Decode.Decoder GrantPermission
permissionDecoder =
    Decode.succeed GrantPermission
        |> required "assignment_slug" Decode.string
        |> optional "identity" (Decode.list Decode.string) []
        |> optional "field_slugs" (Decode.list Decode.string) []


createdGrantDecoder : Decode.Decoder CreatedGrant
createdGrantDecoder =
    Decode.succeed CreatedGrant
        |> required "id" Decode.int
        |> required "token" Decode.string
        |> required "expires_at" Decode.string
