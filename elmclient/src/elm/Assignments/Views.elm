module Assignments.Views exposing (listView)

import Assignments.Model exposing (Assignment)
import Html exposing (Html, a, div, h1, text)
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


listView : WebData (List Assignment) -> Html Msg
listView meetings =
    Html.div [] [ Html.text "woot" ]
