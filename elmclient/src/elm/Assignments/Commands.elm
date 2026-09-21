module Assignments.Commands exposing
    ( beginAndSendAssignmentFieldSubmissions
    , createAssignmentSubmission
    , createRepository
    , fetchAssignmentGradeDistributions
    , fetchAssignmentGradeExceptions
    , fetchAssignmentGrades
    , fetchAssignmentSubmissions
    , fetchAssignments
    , githubJoinUrl
    , loadRepository
    , repositoryResponse
    , repositoryUrl
    , sendAssignmentFieldSubmissions
    )

import Assignments.Model
    exposing
        ( AssignmentGrade
        , AssignmentGradeDistribution
        , AssignmentSlug
        , BeginAndSubmitFailure(..)
        , RepositoryError
        , RepositoryStatus
        , assignmentFieldSubmissionsDecoder
        , assignmentGradeDistributionsDecoder
        , assignmentGradeExceptionsDecoder
        , assignmentGradesDecoder
        , assignmentSubmissionDecoder
        , assignmentSubmissionsDecoder
        , assignmentsDecoder
        , repositoryErrorDecoder
        , repositoryStatusDecoder
        )
import Auth.Commands exposing (fetchForCurrentUser, handleJsonResponse, sendRequestWithJWT)
import Auth.Model exposing (CurrentUser, JWT)
import Dict
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import String
import Task
import Time exposing (Posix)
import Tuple


fetchAssignments : CurrentUser -> Cmd Msg
fetchAssignments currentUser =
    fetchForCurrentUser currentUser fetchAssignmentsUrl assignmentsDecoder Msgs.OnFetchAssignments


fetchAssignmentsUrl : String
fetchAssignmentsUrl =
    "/rest/assignments?order=closed_at&select=*,fields:assignment_fields(*)"


fetchAssignmentSubmissions : CurrentUser -> Cmd Msg
fetchAssignmentSubmissions currentUser =
    fetchForCurrentUser currentUser (fetchAssignmentSubmissionsUrl currentUser) assignmentSubmissionsDecoder Msgs.OnFetchAssignmentSubmissions


fetchAssignmentSubmissionsUrl : CurrentUser -> String
fetchAssignmentSubmissionsUrl currentUser =
    let
        base =
            "/rest/assignment_submissions"

        select =
            "select=*,fields:assignment_field_submissions(*)"

        defaultQuery =
            base
                ++ "?user_id=eq."
                ++ String.fromInt currentUser.id
                ++ "&"
                ++ select
    in
    case currentUser.team_nickname of
        Just nickname ->
            if nickname == "" then
                defaultQuery

            else
                base
                    ++ "?or=(user_id.eq."
                    ++ String.fromInt currentUser.id
                    ++ ",team_nickname.eq."
                    ++ nickname
                    ++ ")&"
                    ++ select

        Nothing ->
            defaultQuery


createAssignmentSubmission : JWT -> AssignmentSlug -> Cmd Msg
createAssignmentSubmission jwt slug =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation"
            , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]

        request =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/assignment_submissions"
                , timeout = Nothing
                , tracker = Nothing
                , expect = Http.expectJson (RemoteData.fromResult >> Msgs.OnBeginAssignmentComplete slug) assignmentSubmissionDecoder
                , body = Http.jsonBody (Encode.object [ ( "assignment_slug", Encode.string slug ) ])
                }
    in
    request


encodeAFS : String -> ( String, String ) -> Encode.Value
encodeAFS assignmentSlug tup =
    -- Encode the assignment field submission into a minimal
    -- json format to be sent to the server.
    Encode.object
        [ ( "assignment_field_slug", Encode.string (Tuple.first tup) )
        , ( "body", Encode.string (Tuple.second tup) )
        , ( "assignment_slug", Encode.string assignmentSlug )
        ]


encodeAFSList : String -> List ( String, String ) -> Encode.Value
encodeAFSList assignmentSlug valueTuples =
    valueTuples
        |> Encode.list (encodeAFS assignmentSlug)


sendAssignmentFieldSubmissions : JWT -> String -> List ( String, String ) -> Cmd Msg
sendAssignmentFieldSubmissions jwt assignmentSlug valueTuples =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation"
            , Http.header "Prefer" "resolution=merge-duplicates"

            -- , Http.header "Accept" "application/vnd.pgrst.object+json"
            ]

        obj =
            List.map

        msg =
            Msgs.OnSubmitAssignmentFieldSubmissionsResponse assignmentSlug

        request =
            Http.request
                { method = "POST"
                , headers = headers
                , url = "/rest/assignment_field_submissions"
                , timeout = Nothing
                , tracker = Nothing
                , expect = Http.expectJson (RemoteData.fromResult >> msg) assignmentFieldSubmissionsDecoder
                , body = Http.jsonBody (encodeAFSList assignmentSlug valueTuples)
                }
    in
    request


{-| Like the connected-apps requests, these ride the browser session cookie:
the endpoint is authapp's, which does the GitHub work on the student's
behalf, and it is not PostgREST, so no JWT header is set.
-}
repositoryUrl : AssignmentSlug -> String
repositoryUrl slug =
    "/auth/assignments/" ++ slug ++ "/repository"


{-| Where the student goes to join the course GitHub organization for this
assignment (issue #399). The server sends it as `join_url` with a
`needs_org_join` status; this is for the one case the client has to draw
that page without a status, when the student comes back from it without
finishing.
-}
githubJoinUrl : AssignmentSlug -> String
githubJoinUrl slug =
    "/auth/github/join?assignment_slug=" ++ slug


{-| Ask authapp to create (or resume creating) the student's repository for
this assignment. The server also begins the assignment submission, which is
why the client does not call `createAssignmentSubmission` first.

`generation` is the request number the reply will carry back (see
`Assignments.Model.RepositoryGenerations`).

Generating from a template can take GitHub a while, so this waits longer
than the status check before giving up.

-}
createRepository : AssignmentSlug -> Int -> Cmd Msg
createRepository slug generation =
    repositoryRequest "POST" (Http.jsonBody (Encode.object [])) 60000 slug
        |> Task.perform (\( now, result ) -> Msgs.OnCreateRepositoryResponse slug generation now result)


loadRepository : AssignmentSlug -> Int -> Cmd Msg
loadRepository slug generation =
    repositoryRequest "GET" Http.emptyBody 15000 slug
        |> Task.perform (\( now, result ) -> Msgs.OnLoadRepositoryResponse slug generation now result)


{-| The request, paired with the time its answer arrived. The poll window
and a `Retry-After` hold are both measured from that moment, and the
five-second `Tick` in the model is too coarse to stand in for it.
-}
repositoryRequest : String -> Http.Body -> Float -> AssignmentSlug -> Task.Task Never ( Posix, Result RepositoryError RepositoryStatus )
repositoryRequest method body timeout slug =
    Http.task
        { method = method
        , headers = [ Http.header "Accept" "application/json" ]
        , url = repositoryUrl slug
        , body = body
        , resolver = Http.stringResolver repositoryResponse
        , timeout = Just timeout
        }
        |> Task.map Ok
        |> Task.onError (Err >> Task.succeed)
        |> Task.andThen (\result -> Time.now |> Task.map (\now -> ( now, result )))


{-| Turn the HTTP reply into the contract's terms.

A 2xx carries a status body; the state in it, not the status code (200 or
202 for `copying`), is what the client acts on. Any other status carries
`{"error": {"code", "retryable"}}` when authapp produced it. A reply from
in front of authapp (a proxy's 429 or 502, say) has no such body, so those
are classified by status alone: worth retrying only for a timeout (408), a
rate limit (429) or a server-side failure (5xx). A 401 means the session
is gone, whatever the body says, and no retry will bring it back.

Every non-2xx also picks up the `Retry-After` header, which a rate limit
sets in seconds; a 429 without one is treated as asking for 30 seconds.

-}
repositoryResponse : Http.Response String -> Result RepositoryError RepositoryStatus
repositoryResponse response =
    case response of
        Http.BadUrl_ _ ->
            Err (noResponse "bad_url" False)

        Http.Timeout_ ->
            Err (noResponse "timeout" True)

        Http.NetworkError_ ->
            Err (noResponse "network_error" True)

        Http.BadStatus_ metadata body ->
            let
                status =
                    metadata.statusCode

                fromStatus =
                    { code =
                        if status == 429 then
                            "rate_limited"

                        else
                            "http_" ++ String.fromInt status
                    , retryable = status == 408 || status == 429 || status >= 500
                    , httpStatus = status
                    , retryAfterSeconds = Nothing
                    }

                error =
                    if status == 401 then
                        { fromStatus | code = "session_expired", retryable = False }

                    else
                        Decode.decodeString repositoryErrorDecoder body
                            |> Result.withDefault fromStatus

                retryAfter =
                    case ( retryAfterSeconds metadata.headers, status == 429 ) of
                        ( Nothing, True ) ->
                            Just 30

                        ( header, _ ) ->
                            header
            in
            Err { error | httpStatus = status, retryAfterSeconds = retryAfter }

        Http.GoodStatus_ metadata body ->
            case Decode.decodeString repositoryStatusDecoder body of
                Ok status ->
                    Ok status

                Err _ ->
                    Err { code = "unexpected_response", retryable = True, httpStatus = metadata.statusCode, retryAfterSeconds = Nothing }


noResponse : String -> Bool -> RepositoryError
noResponse code retryable =
    { code = code, retryable = retryable, httpStatus = 0, retryAfterSeconds = Nothing }


{-| Browsers hand header names over in lower case, but nothing promises it,
so the lookup does not depend on it. Only the delay-seconds form is read;
the HTTP-date form is treated as absent.
-}
retryAfterSeconds : Dict.Dict String String -> Maybe Int
retryAfterSeconds headers =
    headers
        |> Dict.toList
        |> List.filter (\( name, _ ) -> String.toLower name == "retry-after")
        |> List.head
        |> Maybe.andThen (\( _, value ) -> String.toInt (String.trim value))


{-| Begin the assignment and send the answers in one go, for a template
assignment the student has not begun (there the page has no "Begin
assignment" button: the repository or the first submit begins it). The
submission row must exist before the field submissions can, so the two
requests run in sequence. A failure says which of the two it was: after
the first succeeded, the row exists whatever happened to the answers, and
the page has to know that or it would try to create the row again.
-}
beginAndSendAssignmentFieldSubmissions : JWT -> AssignmentSlug -> List ( String, String ) -> Cmd Msg
beginAndSendAssignmentFieldSubmissions jwt assignmentSlug valueTuples =
    let
        headers =
            [ Http.header "Authorization" ("Bearer " ++ jwt)
            , Http.header "Prefer" "return=representation"
            ]

        begin =
            Http.task
                { method = "POST"
                , headers = Http.header "Accept" "application/vnd.pgrst.object+json" :: headers
                , url = "/rest/assignment_submissions"
                , body = Http.jsonBody (Encode.object [ ( "assignment_slug", Encode.string assignmentSlug ) ])
                , resolver = Http.stringResolver (handleJsonResponse assignmentSubmissionDecoder)
                , timeout = Nothing
                }

        send =
            Http.task
                { method = "POST"
                , headers = Http.header "Prefer" "resolution=merge-duplicates" :: headers
                , url = "/rest/assignment_field_submissions"
                , body = Http.jsonBody (encodeAFSList assignmentSlug valueTuples)
                , resolver = Http.stringResolver (handleJsonResponse assignmentFieldSubmissionsDecoder)
                , timeout = Nothing
                }
    in
    begin
        |> Task.mapError BeginFailed
        |> Task.andThen (\_ -> Task.mapError SendFailed send)
        |> Task.attempt (Msgs.OnBeginAndSubmitAssignmentFieldSubmissionsResponse assignmentSlug)


{-| Notice that there is no way to restrict this
set of returned grades to only those owned by the
current user via the API. So, for user with the
'faculty' role, more assignment grades will come
back than are owned by the user.
-}
fetchAssignmentGrades : CurrentUser -> Cmd Msg
fetchAssignmentGrades currentUser =
    fetchForCurrentUser currentUser fetchAssignmentGradesUrl assignmentGradesDecoder Msgs.OnFetchAssignmentGrades


fetchAssignmentGradesUrl : String
fetchAssignmentGradesUrl =
    "/rest/assignment_grades"


fetchAssignmentGradeDistributions : CurrentUser -> Cmd Msg
fetchAssignmentGradeDistributions currentUser =
    fetchForCurrentUser currentUser fetchAssignmentGradeDistributionsUrl assignmentGradeDistributionsDecoder Msgs.OnFetchAssignmentGradeDistributions


fetchAssignmentGradeDistributionsUrl : String
fetchAssignmentGradeDistributionsUrl =
    "/rest/assignment_grade_distributions"


fetchAssignmentGradeExceptions : CurrentUser -> Cmd Msg
fetchAssignmentGradeExceptions currentUser =
    fetchForCurrentUser currentUser fetchAssignmentGradeExceptionsUrl assignmentGradeExceptionsDecoder Msgs.OnFetchAssignmentGradeExceptions


fetchAssignmentGradeExceptionsUrl : String
fetchAssignmentGradeExceptionsUrl =
    "/rest/assignment_grade_exceptions"
