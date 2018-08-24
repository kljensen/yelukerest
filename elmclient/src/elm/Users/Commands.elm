module Users.Commands exposing (..)

import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)
import Msgs exposing (Msg)
import Users.Model exposing (User, usersDecoder)


fetchUsersUrl : String
fetchUsersUrl =
    "/rest/users?order=lastname"


fetchUsers : CurrentUser -> Cmd Msg
fetchUsers currentUser =
    fetchForCurrentUser currentUser fetchUsersUrl usersDecoder Msgs.OnFetchUsers
