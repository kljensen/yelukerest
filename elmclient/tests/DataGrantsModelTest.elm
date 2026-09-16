module DataGrantsModelTest exposing (tests)

import DataGrants.Model
    exposing
        ( addDraftAssignment
        , apiGrantsDecoder
        , createGrantBody
        , draftIsComplete
        , emptyDraft
        , isoDate
        , permissionText
        , setDraftAssignmentSlug
        , setDraftExpiry
        , setDraftField
        , setDraftIdentity
        , setDraftName
        )
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Test exposing (Test, describe, test)
import Time


{-| The example from issue #388: the voting app's grant.
-}
votingAppDraft : DataGrants.Model.GrantDraft
votingAppDraft =
    emptyDraft
        |> setDraftName "  tacky-website voting app "
        |> setDraftAssignmentSlug 0 "tacky-website"
        |> setDraftIdentity 0 "name" True
        |> setDraftIdentity 0 "netid" True
        |> setDraftField 0 "url" True


tests : Test
tests =
    describe "DataGrants.Model"
        [ describe "createGrantBody"
            [ test "encodes the p_assignments shape api.create_api_grant accepts, omitting p_expires_at when blank" <|
                \_ ->
                    createGrantBody votingAppDraft
                        |> Encode.encode 0
                        |> Expect.equal
                            """{"p_name":"tacky-website voting app","p_assignments":[{"assignment_slug":"tacky-website","identity":["netid","name"],"field_slugs":["url"]}]}"""
            , test "sends a chosen expiry as p_expires_at" <|
                \_ ->
                    createGrantBody (setDraftExpiry "2026-12-01" votingAppDraft)
                        |> Encode.encode 0
                        |> Decode.decodeString (Decode.field "p_expires_at" Decode.string)
                        |> Expect.equal (Ok "2026-12-01")
            , test "an identity-free grant sends an empty identity list, not a missing key" <|
                \_ ->
                    emptyDraft
                        |> setDraftName "urls only"
                        |> setDraftAssignmentSlug 0 "tacky-website"
                        |> setDraftField 0 "url" True
                        |> createGrantBody
                        |> Encode.encode 0
                        |> Decode.decodeString (Decode.field "p_assignments" (Decode.list (Decode.field "identity" (Decode.list Decode.string))))
                        |> Expect.equal (Ok [ [] ])
            ]
        , describe "draft editing"
            [ test "changing the assignment clears the fields, which belong to the old assignment" <|
                \_ ->
                    votingAppDraft
                        |> setDraftAssignmentSlug 0 "final-project"
                        |> createGrantBody
                        |> Encode.encode 0
                        |> Decode.decodeString (Decode.field "p_assignments" (Decode.list (Decode.field "field_slugs" (Decode.list Decode.string))))
                        |> Expect.equal (Ok [ [] ])
            , test "is complete only with a name of three characters and a field on every assignment" <|
                \_ ->
                    [ draftIsComplete votingAppDraft
                    , draftIsComplete (setDraftName "ab" votingAppDraft)
                    , draftIsComplete (addDraftAssignment votingAppDraft)
                    , draftIsComplete (setDraftField 0 "url" False votingAppDraft)
                    ]
                        |> Expect.equal [ True, False, False, False ]
            ]
        , describe "permissionText"
            [ test "renders one assignment's permission as plain text" <|
                \_ ->
                    permissionText { assignmentSlug = "tacky-website", identity = [ "netid", "name" ], fieldSlugs = [ "url" ] }
                        |> Expect.equal "tacky-website: netid, name; fields: url"
            , test "says when no identity was granted" <|
                \_ ->
                    permissionText { assignmentSlug = "final-project", identity = [], fieldSlugs = [ "repo", "url" ] }
                        |> Expect.equal "final-project: no identity; fields: repo, url"
            ]
        , describe "apiGrantsDecoder"
            [ test "decodes a listing row from api.api_grants" <|
                \_ ->
                    """
                    [ { "id": 7, "name": "voting app", "created_by": 3
                      , "created_at": "2026-09-16T14:00:00+00:00", "expires_at": "2026-12-15T14:00:00+00:00"
                      , "revoked_by": null, "revoked_at": null, "is_active": true
                      , "permissions": [ { "assignment_slug": "tacky-website", "identity": ["netid", "name"], "field_slugs": ["url"] } ]
                      }
                    ]
                    """
                        |> Decode.decodeString apiGrantsDecoder
                        |> Result.map (List.map (\g -> ( g.name, List.map permissionText g.permissions )))
                        |> Expect.equal (Ok [ ( "voting app", [ "tacky-website: netid, name; fields: url" ] ) ])
            ]
        , test "isoDate is the value an <input type=\"date\"> takes" <|
            \_ ->
                isoDate Time.utc (Time.millisToPosix 1789567200000)
                    |> Expect.equal "2026-09-16"
        ]
