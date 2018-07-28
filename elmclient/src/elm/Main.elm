module Main exposing (..)

import Auth.Commands exposing (fetchCurrentUser)
import Common.Commands exposing (fetchDate)
import Meetings.Commands exposing (fetchMeetings)
import Models exposing (Flags, Model, initialModel)
import Msgs exposing (Msg)
import Navigation exposing (Location)
import Routing
import Update exposing (update)
import View exposing (view)


init : Flags -> Location -> ( Model, Cmd Msg )
init flags location =
    let
        currentRoute =
            Routing.parseLocation location
    in
    ( initialModel flags currentRoute, Cmd.batch [ fetchMeetings, fetchCurrentUser, fetchDate ] )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.none



-- MAIN


main : Program Flags Model Msg
main =
    Navigation.programWithFlags Msgs.OnLocationChange
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }
