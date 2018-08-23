module Engagements.Commands exposing (..)

import Engagements.Model exposing (Engagement, engagementsDecoder)
import Msgs exposing (Msg)
import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)



fetchEngagementsUrl : String
fetchEngagementsUrl =
    "/rest/engagements"

fetchEngagements : CurrentUser -> Cmd Msg
fetchEngagements currentUser =
    fetchForCurrentUser currentUser fetchEngagementsUrl engagementsDecoder Msgs.OnFetchEngagements
