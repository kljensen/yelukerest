module AuthUpdatesTest exposing (tests)

import Auth.Model exposing (CurrentUser)
import Auth.Updates exposing (onFetchCurrentUser)
import Expect
import Http
import RemoteData exposing (WebData)
import Test exposing (Test, describe, test)


{-| `Update.update` does nothing for this message except call this function, so
these cover the whole handler. That matters for the 401: dropping the failure
and leaving `currentUser` at its initial `Loading` is what left signed-out
visitors on the dashboard and the attendance page watching a spinner that could
never resolve, and the views can only offer a login if they are told.
-}
tests : Test
tests =
    describe "Auth.Updates.onFetchCurrentUser"
        [ test "a 401 from /auth/me is recorded, not dropped" <|
            \_ ->
                signedOut
                    |> currentUserAfter (RemoteData.Failure (Http.BadStatus 401))
                    |> RemoteData.isFailure
                    |> Expect.equal True
        , test "a 401 does not leave the page waiting" <|
            \_ ->
                signedOut
                    |> currentUserAfter (RemoteData.Failure (Http.BadStatus 401))
                    |> RemoteData.isLoading
                    |> Expect.equal False
        , test "a network error is recorded too" <|
            \_ ->
                signedOut
                    |> currentUserAfter (RemoteData.Failure Http.NetworkError)
                    |> RemoteData.isFailure
                    |> Expect.equal True
        , test "a signed-in student is recorded" <|
            \_ ->
                signedOut
                    |> currentUserAfter (RemoteData.Success student)
                    |> Expect.equal (RemoteData.Success student)
        , test "a signed-in faculty member is recorded" <|
            \_ ->
                signedOut
                    |> currentUserAfter (RemoteData.Success { student | role = "faculty" })
                    |> Expect.equal (RemoteData.Success { student | role = "faculty" })
        ]


{-| The model as it stands while /auth/me is outstanding.
-}
signedOut : { currentUser : WebData CurrentUser }
signedOut =
    { currentUser = RemoteData.Loading }


currentUserAfter : WebData CurrentUser -> { currentUser : WebData CurrentUser } -> WebData CurrentUser
currentUserAfter response state =
    onFetchCurrentUser response state
        |> Tuple.first
        |> .currentUser


student : CurrentUser
student =
    { id = 42
    , netid = "ada"
    , jwt = "jwt"
    , role = "student"
    , nickname = "ada"
    , team_nickname = Nothing
    }
