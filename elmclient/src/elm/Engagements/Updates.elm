module Engagements.Updates exposing (onSSETableChange)

import Auth.Model exposing (isLoggedInFacultyOrTA)
import Engagements.Commands exposing (fetchEngagements)
import Models exposing (Model)
import Msgs exposing (Msg)
import String exposing (contains)
import Users.Commands exposing (fetchUsers)


{-| Handle an SSE tablechange event. This function will check the
routingKey to see if it indicates that either the `user` or the
`engagement` table was changed. The function accepts a tuple of
Model and Cmd Msg as its second argument and returns the same
kind of tuple. If the `user` or `engagement` table is changed,
extra commands will be added: we'll re-fetch the user or the
engagement data.
-}
onSSETableChange : String -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
onSSETableChange routingKey ( oldModel, oldCmd ) =
    let
        usersUpdated =
            contains ".table-user." routingKey

        engagementsUpdated =
            contains ".table-engagement." routingKey

        ( userCmd, engagementCmd ) =
            case isLoggedInFacultyOrTA oldModel.currentUser of
                Ok user ->
                    ( if usersUpdated then
                        fetchUsers user
                      else
                        Cmd.none
                    , if engagementsUpdated then
                        fetchEngagements user
                      else
                        Cmd.none
                    )

                _ ->
                    ( Cmd.none, Cmd.none )
    in
    ( oldModel, Cmd.batch [ userCmd, engagementCmd ] )
