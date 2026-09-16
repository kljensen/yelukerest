module DataGrants.Views exposing (DataGrantsPage, page)

import Assignments.Model exposing (Assignment)
import Auth.Model exposing (CurrentUser)
import Auth.Views exposing (loginLink)
import DataGrants.Model
    exposing
        ( ApiGrant
        , CreatedGrant
        , DraftAssignment
        , GrantDraft
        , allIdentities
        , draftIsComplete
        , isoDate
        , permissionText
        )
import Html exposing (Html, button, code, div, fieldset, h1, h2, input, label, legend, li, option, p, select, span, table, tbody, td, text, th, thead, tr, ul)
import Html.Attributes exposing (attribute, checked, class, disabled, for, id, placeholder, selected, type_, value)
import Html.Events exposing (onCheck, onClick, onInput)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Set exposing (Set)
import Time exposing (Posix, Zone)
import Users.Model exposing (User)


{-| The slice of `Models.Model` this page reads, so View.elm can hand it the
model without the page depending on every field.
-}
type alias DataGrantsPage a =
    { a
        | currentUser : WebData CurrentUser
        , current_date : Maybe Posix
        , assignments : WebData (List Assignment)
        , users : WebData (List User)
        , dataGrants : WebData (List ApiGrant)
        , justCreatedDataGrant : Maybe CreatedGrant
        , dataGrantCreateError : Maybe String
        , dataGrantDraft : GrantDraft
        , pendingDataGrantRevokes : Set Int
    }


{-| Faculty only: `api.api_grants` and both RPCs refuse every other role, so
anyone else gets told rather than shown an empty page that then fails.
-}
page : Zone -> DataGrantsPage a -> Html Msg
page zone model =
    case model.currentUser of
        RemoteData.Success user ->
            if user.role == "faculty" then
                facultyPage zone model

            else
                p [] [ text "Only faculty can manage data grants." ]

        RemoteData.Loading ->
            p [] [ text "Loading…" ]

        _ ->
            loginLink


facultyPage : Zone -> DataGrantsPage a -> Html Msg
facultyPage zone model =
    div [ class "api-tokens" ]
        [ h1 [] [ text "Data grants" ]
        , introduction
        , justCreatedView model.justCreatedDataGrant
        , createErrorView model.dataGrantCreateError
        , createFormView zone model.current_date (webDataList model.assignments) model.dataGrantDraft
        , h2 [] [ text "Grants" ]
        , grantTableView (webDataList model.users) model.dataGrants model.pendingDataGrantRevokes
        ]


introduction : Html Msg
introduction =
    div [ class "api-tokens-intro" ]
        [ p []
            [ text "A data grant lets an app -- a voting page, a leaderboard -- read exactly the submissions you name: which assignments, which fields, and which of the submitter's identity attributes. It is not a person's token and it can read nothing else. The app sends the credential as a header:" ]
        , code [ class "api-token-usage" ] [ text "Authorization: Bearer <the grant credential>" ]
        , p []
            [ text "and reads from "
            , code [] [ text "/rest/rpc/granted_submissions" ]
            , text ". A grant cannot be changed once created: to change what an app may see, revoke it and create another."
            ]
        ]


{-| The credential exists outside the database exactly once, here.
-}
justCreatedView : Maybe CreatedGrant -> Html Msg
justCreatedView justCreated =
    case justCreated of
        Nothing ->
            text ""

        Just created ->
            div [ class "api-token-created" ]
                [ h2 [] [ text ("Grant created (id " ++ String.fromInt created.id ++ ")") ]
                , p [ class "api-token-warning" ]
                    [ text "Copy this credential now. It cannot be shown again." ]
                , div [ class "api-token-secret-row" ]
                    [ code [ class "api-token-secret" ] [ text created.token ]

                    -- init.js copies any element carrying data-copy-text.
                    , button
                        [ type_ "button"
                        , attribute "data-copy-text" created.token
                        , attribute "aria-label" "copy the grant credential"
                        ]
                        [ text "Copy" ]
                    ]
                , p []
                    [ text "Put it in the app's server-side configuration, never in a browser or a repository. It expires "
                    , text (shortDate created.expiresAt)
                    , text ", and you can revoke it below at any time."
                    ]
                , button [ onClick Msgs.DismissCreatedDataGrant ] [ text "I have copied it" ]
                ]


createErrorView : Maybe String -> Html Msg
createErrorView error =
    case error of
        Nothing ->
            text ""

        Just message ->
            p [ class "error data-grant-error" ] [ text ("The grant was not created: " ++ message) ]


createFormView : Zone -> Maybe Posix -> List Assignment -> GrantDraft -> Html Msg
createFormView zone now assignments draft =
    let
        -- Prefill the server's own default, 90 days, and bound the picker at
        -- the 180-day cap data.api_grant enforces. Before the clock is known
        -- the field is blank and the server default applies.
        daysFromNow days =
            Maybe.map (\t -> isoDate zone (Time.millisToPosix (Time.posixToMillis t + days * 86400000))) now

        expiryValue =
            case draft.expiresAt of
                Just date ->
                    date

                Nothing ->
                    Maybe.withDefault "" (daysFromNow 90)

        bound name days =
            Maybe.map (attribute name) (daysFromNow days)
    in
    div [ class "api-token-create" ]
        [ h2 [] [ text "Create a grant" ]
        , div [ class "api-token-field" ]
            [ label [ class "api-token-field-label", for "data-grant-name" ] [ text "Name" ]
            , input
                [ id "data-grant-name"
                , type_ "text"
                , placeholder "tacky-website voting app"
                , value draft.name
                , onInput Msgs.SetDataGrantDraftName
                ]
                []
            ]
        , div [ class "api-token-field" ]
            [ label [ class "api-token-field-label", for "data-grant-expiry" ] [ text "Expires" ]
            , input
                (List.filterMap identity
                    [ Just (id "data-grant-expiry")
                    , Just (type_ "date")
                    , Just (value expiryValue)
                    , Just (onInput Msgs.SetDataGrantDraftExpiry)
                    , bound "min" 1
                    , bound "max" 180
                    ]
                )
                []
            , p [ class "data-grant-help" ] [ text "90 days by default; at most 180 days from today." ]
            ]
        , div [] (List.indexedMap (draftAssignmentView assignments) draft.assignments)
        , p []
            [ button [ type_ "button", onClick Msgs.AddDataGrantDraftAssignment ] [ text "Add another assignment" ] ]
        , button
            [ onClick Msgs.CreateDataGrant
            , disabled (not (draftIsComplete draft))
            ]
            [ text "Create grant" ]
        ]


draftAssignmentView : List Assignment -> Int -> DraftAssignment -> Html Msg
draftAssignmentView assignments index row =
    let
        selectId =
            "data-grant-assignment-" ++ String.fromInt index

        chosen =
            List.filter (\a -> a.slug == row.assignmentSlug) assignments |> List.head

        assignmentOption a =
            option [ value a.slug, selected (a.slug == row.assignmentSlug) ] [ text a.slug ]
    in
    fieldset [ class "api-token-scopes data-grant-assignment" ]
        [ legend [] [ text ("Assignment " ++ String.fromInt (index + 1)) ]
        , div [ class "api-token-field" ]
            [ label [ class "api-token-field-label", for selectId ] [ text "Assignment" ]
            , select [ id selectId, onInput (Msgs.SetDataGrantDraftAssignmentSlug index) ]
                (option [ value "", selected (row.assignmentSlug == "") ] [ text "Choose an assignment…" ]
                    :: List.map assignmentOption assignments
                )
            ]
        , div [ class "api-token-field" ]
            [ span [ class "api-token-field-label" ] [ text "Identity the app may see" ]
            , div [ class "data-grant-checks" ]
                (List.map
                    (\attributeName ->
                        checkbox (Set.member attributeName row.identity) (Msgs.SetDataGrantDraftIdentity index attributeName) attributeName
                    )
                    allIdentities
                )
            ]
        , div [ class "api-token-field" ]
            [ span [ class "api-token-field-label" ] [ text "Fields the app may read" ]
            , case chosen of
                Nothing ->
                    p [ class "data-grant-help" ] [ text "Choose an assignment first." ]

                Just assignment ->
                    div [ class "data-grant-checks" ]
                        (assignment.fields
                            |> List.sortBy .display_order
                            |> List.map
                                (\field ->
                                    checkbox (Set.member field.slug row.fieldSlugs) (Msgs.SetDataGrantDraftField index field.slug) field.slug
                                )
                        )
            ]
        , button [ type_ "button", onClick (Msgs.RemoveDataGrantDraftAssignment index) ] [ text "Remove this assignment" ]
        ]


checkbox : Bool -> (Bool -> Msg) -> String -> Html Msg
checkbox isChecked toMsg name =
    label [ class "data-grant-check" ]
        [ input [ type_ "checkbox", checked isChecked, onCheck toMsg ] []
        , span [ class "api-token-scope-name" ] [ text name ]
        ]


grantTableView : List User -> WebData (List ApiGrant) -> Set Int -> Html Msg
grantTableView users grants pendingRevokes =
    case grants of
        RemoteData.NotAsked ->
            text ""

        RemoteData.Loading ->
            p [] [ text "Loading…" ]

        RemoteData.Failure _ ->
            p [ class "error" ] [ text "Could not load the grants." ]

        RemoteData.Success [] ->
            p [] [ text "There are no data grants." ]

        RemoteData.Success list ->
            table [ class "api-token-table" ]
                [ thead []
                    [ tr []
                        [ th [] [ text "Name" ]
                        , th [] [ text "May read" ]
                        , th [] [ text "Expires" ]
                        , th [] [ text "Created" ]
                        , th [] [ text "Revoked" ]
                        , th [] [ text "" ]
                        ]
                    ]
                , tbody [] (List.map (grantRow users pendingRevokes) list)
                ]


grantRow : List User -> Set Int -> ApiGrant -> Html Msg
grantRow users pendingRevokes grant =
    let
        status =
            if grant.revokedAt /= Nothing then
                "revoked"

            else if not grant.isActive then
                "expired"

            else
                "active"

        byAt who when =
            userLabel users who ++ ", " ++ shortDate when
    in
    tr [ class ("api-token-row api-token-" ++ status) ]
        [ td [] [ text grant.name ]
        , td [] [ ul [] (List.map (\permission -> li [] [ text (permissionText permission) ]) grant.permissions) ]
        , td [] [ text (shortDate grant.expiresAt) ]
        , td [] [ text (byAt grant.createdBy grant.createdAt) ]
        , td []
            [ text
                (case ( grant.revokedBy, grant.revokedAt ) of
                    ( Just who, Just when ) ->
                        byAt who when

                    _ ->
                        ""
                )
            ]
        , td []
            [ if status == "active" then
                button
                    [ onClick (Msgs.RevokeDataGrant grant.id)
                    , disabled (Set.member grant.id pendingRevokes)
                    ]
                    [ text
                        (if Set.member grant.id pendingRevokes then
                            "Revoking…"

                         else
                            "Revoke"
                        )
                    ]

              else
                span [ class "api-token-status" ] [ text status ]
            ]
        ]


{-| The view reports user ids; faculty have the roster loaded, so show the
netid when it is there and the id when it is not.
-}
userLabel : List User -> Int -> String
userLabel users userId =
    List.filter (\u -> u.id == userId) users
        |> List.head
        |> Maybe.map .netid
        |> Maybe.withDefault ("user " ++ String.fromInt userId)


webDataList : WebData (List a) -> List a
webDataList webData =
    RemoteData.withDefault [] webData


shortDate : String -> String
shortDate iso =
    String.left 10 iso
