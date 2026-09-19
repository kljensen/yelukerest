module Subscriptions exposing (subscriptions)

import Assignments.Updates exposing (isPollingActiveRoute)
import Models exposing (Model)
import Msgs exposing (Msg)
import Time exposing (Posix)


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Time.every 5000 Msgs.Tick

        -- The repository poll timer runs only while the assignment on
        -- screen has a copy being waited on;
        -- `Assignments.Updates.onRepositoryPollTick` decides what each tick
        -- does.
        , if isPollingActiveRoute model then
            Time.every 3000 Msgs.OnRepositoryPollTick

          else
            Sub.none
        ]
