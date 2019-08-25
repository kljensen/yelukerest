module Engagements.Views exposing (maybeEditEngagements)

import Auth.Model exposing (CurrentUser, isFacultyOrTA)
import Engagements.Model exposing (Engagement, participationEnum)
import Html exposing (Html)
import Html.Attributes as Attrs
import Html.Events as Events
import Meetings.Model exposing (Meeting)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Users.Model exposing (User, niceName)


type alias EngagementData =
    { currentUser : CurrentUser
    , userQuery : Maybe String
    , users : List User
    , engagements : List Engagement
    , meetings : List Meeting
    }


makeEngagementData : CurrentUser -> Maybe String -> List User -> List Engagement -> List Meeting -> EngagementData
makeEngagementData currentUser userQuery users engagements meetings =
    { currentUser = currentUser
    , userQuery = userQuery
    , users = users
    , engagements = engagements
    , meetings = meetings
    }


mergeEngagementData : WebData CurrentUser -> Maybe String -> WebData (List User) -> WebData (List Engagement) -> WebData (List Meeting) -> WebData EngagementData
mergeEngagementData wdCurrentUser userQuery wdUsers wdEngagements wdMeetings =
    RemoteData.map makeEngagementData wdCurrentUser
        |> RemoteData.andMap (RemoteData.Success userQuery)
        |> RemoteData.andMap wdUsers
        |> RemoteData.andMap wdEngagements
        |> RemoteData.andMap wdMeetings


maybeEditEngagements : WebData CurrentUser -> Maybe String -> WebData (List User) -> WebData (List Engagement) -> WebData (List Meeting) -> String -> Html.Html Msg
maybeEditEngagements wdCurrentUser engagementuserQuery wdUsers wdEngagements wdMeetings meetingSlug =
    let
        neededData =
            mergeEngagementData wdCurrentUser engagementuserQuery wdUsers wdEngagements wdMeetings
    in
    case neededData of
        RemoteData.Success data ->
            if isFacultyOrTA data.currentUser.role then
                editEngagements data.currentUser data.userQuery data.users data.engagements data.meetings meetingSlug

            else
                Html.text "forbidden"

        RemoteData.Loading ->
            Html.text "Loading..."

        RemoteData.NotAsked ->
            Html.text "Loading..."

        RemoteData.Failure _ ->
            Html.text "Failed to load data!"


editEngagements : CurrentUser -> Maybe String -> List User -> List Engagement -> List Meeting -> String -> Html.Html Msg
editEngagements currentUser userQuery users engagements meetings meetingSlug =
    let
        maybeMeeting =
            meetings
                |> List.filter (\meeting -> meeting.slug == meetingSlug)
                |> List.head
    in
    case maybeMeeting of
        Just meeting ->
            editEngagementsForMeeting currentUser userQuery users engagements meeting

        Nothing ->
            Html.text "No such meeting"


editEngagementsForMeeting : CurrentUser -> Maybe String -> List User -> List Engagement -> Meeting -> Html.Html Msg
editEngagementsForMeeting currentUser userQuery users engagements meeting =
    let
        renderUser =
            userEngagementSelect meeting.slug engagements

        matchingUsers =
            searchUsers users userQuery

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


searchUsers : List User -> Maybe String -> List User
searchUsers users userQuery =
    case userQuery of
        Nothing ->
            users

        Just q ->
            users
                |> List.filter (userMatchesQuery q)


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


userEngagementSelect : String -> List Engagement -> User -> Html.Html Msg
userEngagementSelect meetingSlug engagements user =
    let
        maybeEngagement =
            engagements
                |> List.filter (\e -> e.user_id == user.id && e.meeting_slug == meetingSlug)
                |> List.head

        renderOptions =
            participationSelectOption maybeEngagement

        onInputHandler =
            Msgs.OnChangeEngagement meetingSlug user.id
    in
    Html.div [ Attrs.class "student" ]
        [ Html.span [] [ Html.text (niceName user) ]
        , Html.div
            [ Attrs.class "radio-holder"
            , Events.onInput onInputHandler
            ]
            (List.map (participationRadioOption user.id maybeEngagement) participationEnum)

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

        -- x =
        --     Debug.log "(value, isSelected)" ( optionValue, isSelected )
    in
    Html.option
        [ Attrs.value optionValue
        , Attrs.selected isSelected
        ]
        [ Html.text optionValue ]


participationRadioOption : Int -> Maybe Engagement -> String -> Html.Html Msg
participationRadioOption userId maybeEngagement optionValue =
    let
        isSelected =
            case maybeEngagement of
                Nothing ->
                    False

                Just engagement ->
                    engagement.participation == optionValue

        -- x =
        --     Debug.log "(value, isSelected)" ( optionValue, isSelected )
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
