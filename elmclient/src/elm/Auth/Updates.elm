module Auth.Updates exposing (AuthState, onFetchCurrentUser)

import Assignments.Commands
    exposing
        ( fetchAssignmentGradeDistributions
        , fetchAssignmentGradeExceptions
        , fetchAssignmentGrades
        , fetchAssignmentSubmissions
        , fetchAssignments
        )
import Auth.Model exposing (CurrentUser, isFacultyOrTA)
import Engagements.Commands exposing (fetchEngagements)
import Msgs exposing (Msg)
import Quizzes.Commands
    exposing
        ( fetchQuizArtifacts
        , fetchQuizGradeDistributions
        , fetchQuizGrades
        , fetchQuizSubmissions
        , fetchQuizzes
        )
import RemoteData exposing (WebData)
import Users.Commands exposing (fetchUserSecrets, fetchUsers)


{-| The slice of the model that knowing who is signed in touches. Extensible
for the same reason as `Engagements.Updates.EngagementState`: the full model
holds a `Browser.Navigation.Key` that no test can construct, and this
transition is worth testing.
-}
type alias AuthState a =
    { a | currentUser : WebData CurrentUser }


{-| Handle the answer from /auth/me.

The failure is recorded, not dropped. Signed out, /auth/me 401s; leaving
`currentUser` at its initial `Loading` left every page that waits on it —
the dashboard and the attendance page among them — showing a spinner that
could never resolve, with no route to a login.

-}
onFetchCurrentUser : WebData CurrentUser -> AuthState a -> ( AuthState a, Cmd Msg )
onFetchCurrentUser response state =
    case response of
        RemoteData.Success user ->
            let
                newUserCmds =
                    Cmd.batch
                        [ fetchAssignments user
                        , fetchQuizzes user
                        , fetchQuizGradeDistributions user
                        , fetchAssignmentSubmissions user
                        , fetchQuizSubmissions user
                        , fetchQuizArtifacts user
                        , fetchQuizGrades user
                        , fetchQuizGradeDistributions user
                        , fetchAssignmentGrades user
                        , fetchAssignmentGradeDistributions user
                        , fetchAssignmentGradeExceptions user
                        , fetchUserSecrets user
                        ]
            in
            if isFacultyOrTA user.role then
                ( { state | currentUser = response }
                , Cmd.batch
                    [ newUserCmds
                    , fetchEngagements user
                    , fetchUsers user
                    ]
                )

            else
                ( { state | currentUser = response }, newUserCmds )

        _ ->
            ( { state | currentUser = response }, Cmd.none )
