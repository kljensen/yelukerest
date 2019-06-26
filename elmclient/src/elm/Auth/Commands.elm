module Auth.Commands exposing
    ( fetchCurrentUser
    , fetchCurrentUserUrl
    , fetchForCurrentUser
    , fetchForJWT
    , handleJsonResponse
    , requestForJWT
    , sendRequestWithJWT
    )

import Auth.Model exposing (CurrentUser, JWT, currentUserDecoder)
import Http
import Json.Decode as Decode
import Msgs exposing (Msg)
import RemoteData exposing (WebData)


fetchCurrentUser : Cmd Msg
fetchCurrentUser =
    Http.get
        { url = fetchCurrentUserUrl
        , expect = Http.expectJson (RemoteData.fromResult >> Msgs.OnFetchCurrentUser) currentUserDecoder
        }


fetchCurrentUserUrl : String
fetchCurrentUserUrl =
    "/auth/me"


fetchForCurrentUser : CurrentUser -> String -> Decode.Decoder a -> (WebData a -> Msg) -> Cmd Msg
fetchForCurrentUser currentUser url decoder data2msg =
    fetchForJWT currentUser.jwt url decoder data2msg


fetchForJWT : String -> String -> Decode.Decoder a -> (WebData a -> Msg) -> Cmd Msg
fetchForJWT jwt url decoder data2msg =
    sendRequestWithJWT jwt url "GET" Http.emptyBody decoder data2msg


sendRequestWithJWT : JWT -> String -> String -> Http.Body -> Decode.Decoder a -> (WebData a -> Msg) -> Cmd Msg
sendRequestWithJWT jwt url method decoder body data2msg =
    requestForJWT jwt url method decoder body data2msg


requestForJWT : JWT -> String -> String -> Http.Body -> Decode.Decoder a -> (WebData a -> Msg) -> Cmd Msg
requestForJWT jwt url method body decoder data2msg =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            ]

        request =
            Http.request
                { method = method
                , headers = headers
                , url = url
                , timeout = Nothing
                , expect = Http.expectJson (RemoteData.fromResult >> data2msg) decoder
                , body = body
                , tracker = Nothing
                }
    in
    request



-- |> Msgs.OnFetchCurrentUser
-- |> Cmd.map msg


handleJsonResponse : Decode.Decoder a -> Http.Response String -> Result Http.Error a
handleJsonResponse decoder response =
    -- This is mostly used for tasks when I need to chain http requests. Though, I
    -- feel like I ought to rewrite the server side API such that chaining is not
    -- required.
    -- See https://korban.net/posts/elm/2019-02-15-combining-http-requests-with-task-in-elm/
    case response of
        Http.BadUrl_ url ->
            Err (Http.BadUrl url)

        Http.Timeout_ ->
            Err Http.Timeout

        Http.BadStatus_ { statusCode } _ ->
            Err (Http.BadStatus statusCode)

        Http.NetworkError_ ->
            Err Http.NetworkError

        Http.GoodStatus_ _ body ->
            case Decode.decodeString decoder body of
                Err _ ->
                    Err (Http.BadBody body)

                Ok result ->
                    Ok result
