module Users.Commands exposing (fetchUserSecrets, fetchUsers, fetchUsersUrl)

import Auth.Commands exposing (fetchForCurrentUser)
import Auth.Model exposing (CurrentUser)
import Msgs exposing (Msg)
import Users.Model exposing (User, userSecretsDecoder, usersDecoder)


fetchUsersUrl : String
fetchUsersUrl =
    "/rest/users?order=lastname"


fetchUsers : CurrentUser -> Cmd Msg
fetchUsers currentUser =
    fetchForCurrentUser currentUser fetchUsersUrl usersDecoder Msgs.OnFetchUsers


fetchUserSecretsUrl : String
fetchUserSecretsUrl =
    "/rest/user_secrets"


fetchUserSecrets : CurrentUser -> Cmd Msg
fetchUserSecrets currentUser =
    let
        baseUrl =
            "/rest/user_secrets?"

        idQuery =
            "user_id.eq." ++ String.fromInt currentUser.id

        url =
            case currentUser.team_nickname of
                Just nickname ->
                    baseUrl
                        ++ "or=("
                        ++ idQuery
                        ++ ",team_nickname.eq."
                        ++ nickname
                        ++ ")"

                Nothing ->
                    baseUrl ++ "user_id=eq." ++ String.fromInt currentUser.id
    in
    fetchForCurrentUser currentUser url userSecretsDecoder Msgs.OnFetchUserSecrets
