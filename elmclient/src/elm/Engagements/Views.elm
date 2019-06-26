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
    , users : List User
    , engagements : List Engagement
    , meetings : List Meeting
    }


makeEngagementData : CurrentUser -> List User -> List Engagement -> List Meeting -> EngagementData
makeEngagementData currentUser users engagements meetings =
    { currentUser = currentUser
    , users = users
    , engagements = engagements
    , meetings = meetings
    }


mergeEngagementData : WebData CurrentUser -> WebData (List User) -> WebData (List Engagement) -> WebData (List Meeting) -> WebData EngagementData
mergeEngagementData wdCurrentUser wdUsers wdEngagements wdMeetings =
    RemoteData.map makeEngagementData wdCurrentUser
        |> RemoteData.andMap wdUsers
        |> RemoteData.andMap wdEngagements
        |> RemoteData.andMap wdMeetings


maybeEditEngagements : WebData CurrentUser -> WebData (List User) -> WebData (List Engagement) -> WebData (List Meeting) -> Int -> Html.Html Msg
maybeEditEngagements wdCurrentUser wdUsers wdEngagements wdMeetings meetingID =
    let
        neededData =
            mergeEngagementData wdCurrentUser wdUsers wdEngagements wdMeetings
    in
    case neededData of
        RemoteData.Success data ->
            if isFacultyOrTA data.currentUser.role then
                editEngagements data.currentUser data.users data.engagements data.meetings meetingID

            else
                Html.text "forbidden"

        RemoteData.Loading ->
            Html.text "Loading..."

        RemoteData.NotAsked ->
            Html.text "Loading..."

        RemoteData.Failure _ ->
            Html.text "Failed to load data!"


editEngagements : CurrentUser -> List User -> List Engagement -> List Meeting -> Int -> Html.Html Msg
editEngagements currentUser users engagements meetings meetingID =
    let
        maybeMeeting =
            meetings
                |> List.filter (\meeting -> meeting.id == meetingID)
                |> List.head
    in
    case maybeMeeting of
        Just meeting ->
            editEngagementsForMeeting currentUser users engagements meeting

        Nothing ->
            Html.text "No such meeting"


editEngagementsForMeeting : CurrentUser -> List User -> List Engagement -> Meeting -> Html.Html Msg
editEngagementsForMeeting currentUser users engagements meeting =
    let
        renderUser =
            userEngagementSelect meeting.id engagements
    in
    Html.div []
        [ Html.h2 [] [ Html.text ("Attendance for meeting id=" ++ String.fromInt meeting.id ++ ": " ++ meeting.title) ]
        , Html.div [] (List.map renderUser users)
        ]


userEngagementSelect : Int -> List Engagement -> User -> Html.Html Msg
userEngagementSelect meetingID engagements user =
    let
        -- x =
        --     Debug.log "meetingID, userID" ( meetingID, user.id )
        maybeEngagement =
            engagements
                |> List.filter (\e -> e.user_id == user.id && e.meeting_id == meetingID)
                |> List.head

        renderOptions =
            participationSelectOption maybeEngagement

        onInputHandler =
            Msgs.OnChangeEngagement meetingID user.id
    in
    Html.p []
        [ Html.label [ Attrs.for (String.fromInt user.id) ] [ Html.text (niceName user) ]
        , Html.select
            [ Events.onInput onInputHandler, Attrs.name (String.fromInt user.id), Attrs.class "engagement" ]
            (List.map renderOptions participationEnum)
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
