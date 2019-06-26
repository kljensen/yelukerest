module Main exposing (init, main)

import Auth.Commands exposing (fetchCurrentUser)
import Browser
import Common.Commands exposing (updateDate)
import Meetings.Commands exposing (fetchMeetings)
import Models exposing (Flags, Model, initialModel)
import Msgs exposing (Msg)
import Routing
import Subscriptions exposing (subscriptions)
import Update exposing (update)
import Url exposing (Url)
import View exposing (view)


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        currentRoute =
            Routing.parseLocation flags.location

        m =
            initialModel flags currentRoute
    in
    ( initialModel flags currentRoute, Cmd.batch [ fetchMeetings, fetchCurrentUser, updateDate ] )


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }
