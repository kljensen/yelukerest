module Users.Commands exposing (..)

import Users.Model exposing (User, usersDecoder)
import Msgs exposing (Msg)
import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)



fetchUsersUrl : String
fetchUsersUrl =
    "/rest/users"

fetchUsers : CurrentUser -> Cmd Msg
fetchUsers currentUser =
    fetchForCurrentUser currentUser fetchUsersUrl usersDecoder Msgs.OnFetchUsers
