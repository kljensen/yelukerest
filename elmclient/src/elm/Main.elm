module Main exposing (init, main)

import Auth.Commands exposing (fetchCurrentUser)
import Browser
import Browser.Navigation exposing (Key)
import Common.Commands exposing (getTimeZone, getTimeZoneName, updateDate)
import Meetings.Commands exposing (fetchMeetings)
import Models exposing (Flags, Model, initialModel)
import Msgs exposing (BrowserLocation(..), Msg)
import Routing
import Subscriptions exposing (subscriptions)
import Update exposing (update)
import Url exposing (Url)
import View exposing (view)


init : Flags -> Url -> Key -> ( Model, Cmd Msg )
init flags url key =
    let
        currentRoute =
            Routing.parseLocation (StringLocation flags.location)

        m =
            initialModel flags currentRoute key
    in
    ( m
    , Cmd.batch
        [ fetchMeetings
        , fetchCurrentUser
        , updateDate
        , getTimeZone
        , getTimeZoneName
        ]
    )



-- See https://mmhaskell.com/blog/2018/11/12/elm-iv-navigation


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        , onUrlChange = \u -> Msgs.OnLocationChange (UrlLocation u)
        , onUrlRequest = Msgs.LinkClicked
        }
