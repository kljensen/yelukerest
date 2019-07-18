module Update exposing (listToDict, setSseAndDo, sseMessageDecoder, update, valuesFromDict)

import Assignments.Commands
    exposing
        ( createAssignmentSubmission
        , fetchAssignmentGradeDistributions
        , fetchAssignmentGradeExceptions
        , fetchAssignmentGrades
        , fetchAssignmentSubmissions
        , fetchAssignments
        , sendAssignmentFieldSubmissions
        )
import Assignments.Model exposing (valuesForSubmissionID)
import Assignments.Updates
    exposing
        ( onFetchAssignmentGradeDistributions
        , onFetchAssignmentGrades
        )
import Auth.Model exposing (isFacultyOrTA)
import Browser exposing (UrlRequest(..))
import Browser.Navigation exposing (load, pushUrl)
import Dict exposing (Dict)
import Engagements.Commands
    exposing
        ( fetchEngagements
        , submitEngagement
        )
import Engagements.Updates exposing (onSSETableChange)
import Json.Decode exposing (decodeString, string)
import Models exposing (Model, Route(..))
import Msgs exposing (BrowserLocation(..), Msg)
import Quizzes.Commands
    exposing
        ( createQuizSubmission
        , fetchQuizAnswers
        , fetchQuizGradeDistributions
        , fetchQuizGradeExceptions
        , fetchQuizGrades
        , fetchQuizQuestions
        , fetchQuizSubmissions
        , fetchQuizzes
        )
import Quizzes.Updates
    exposing
        ( onBeginQuiz
        , onBeginQuizComplete
        , onFetchQuizGradeDistributions
        , onFetchQuizGrades
        , onFetchQuizSubmissions
        , onSubmitQuizAnswers
        , onSubmitQuizAnswersComplete
        , takeQuiz
        )
import RemoteData exposing (WebData)
import Routing exposing (parseLocation)
import SSE exposing (SseAccess, withListener)
import Set exposing (Set)
import Time exposing (Posix)
import Url
import Users.Commands exposing (fetchUsers)


valuesFromDict : Dict comparable b -> List comparable -> List ( comparable, b )
valuesFromDict theDict theList =
    -- Get only the values from the dict where the key is
    -- in the list
    theDict
        |> Dict.filter (\k -> \_ -> List.member k theList)
        |> Dict.toList


listToDict : (a -> comparable) -> List a -> Dict.Dict comparable a
listToDict getKey values =
    -- https://gist.github.com/Warry/b4382a5b4373de57f5ba
    Dict.fromList (List.map (\v -> ( getKey v, v )) values)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Msgs.LinkClicked urlRequest ->
            case urlRequest of
                Internal url ->
                    case parseLocation (UrlLocation url) of
                        NotFoundRoute ->
                            ( model, load (Url.toString url) )

                        _ ->
                            ( model, pushUrl model.navKey (Url.toString url) )

                External href ->
                    ( model, load href )

        Msgs.OnLocationChange location ->
            let
                newRoute =
                    parseLocation location
            in
            ( { model | route = newRoute }, Cmd.none )

        Msgs.Tick theTime ->
            ( { model | current_date = Just theTime }, Cmd.none )

        Msgs.OnFetchMeetings response ->
            ( { model | meetings = response }, Cmd.none )

        Msgs.OnFetchAssignments response ->
            ( { model | assignments = response }, Cmd.none )

        Msgs.OnFetchAssignmentSubmissions response ->
            ( { model | assignmentSubmissions = response }, Cmd.none )

        Msgs.OnFetchQuizzes response ->
            ( { model | quizzes = response }, Cmd.none )

        Msgs.OnFetchCurrentUser response ->
            case response of
                RemoteData.Success user ->
                    let
                        newUserModel =
                            { model | currentUser = response }

                        newUserCmds =
                            Cmd.batch
                                [ fetchAssignments user
                                , fetchQuizzes user
                                , fetchQuizGradeDistributions user
                                , fetchQuizGradeExceptions user
                                , fetchAssignmentSubmissions user
                                , fetchQuizSubmissions user
                                , fetchQuizGrades user
                                , fetchQuizGradeDistributions user
                                , fetchAssignmentGrades user
                                , fetchAssignmentGradeDistributions user
                                , fetchAssignmentGradeExceptions user
                                ]

                        ( sseUserModel, sseCmd ) =
                            setSseAndDo newUserModel (withListener "tablechange" sseMessageDecoder)
                    in
                    if isFacultyOrTA user.role then
                        ( sseUserModel
                        , Cmd.batch
                            [ newUserCmds
                            , sseCmd
                            , fetchEngagements user
                            , fetchUsers user
                            ]
                        )

                    else
                        ( newUserModel, newUserCmds )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnBeginAssignment assignmentSlug ->
            let
                pba =
                    Dict.insert assignmentSlug RemoteData.Loading model.pendingBeginAssignments
            in
            case model.currentUser of
                RemoteData.Success user ->
                    ( { model | pendingBeginAssignments = pba }, Cmd.batch [ createAssignmentSubmission user.jwt assignmentSlug ] )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnBeginAssignmentComplete assignmentSlug response ->
            case ( model.assignmentSubmissions, response ) of
                ( _, RemoteData.Failure error ) ->
                    ( { model | pendingBeginAssignments = Dict.update assignmentSlug (\_ -> Just (RemoteData.Failure error)) model.pendingBeginAssignments }, Cmd.none )

                ( RemoteData.Success submissions, RemoteData.Success newSubmission ) ->
                    -- Append this submission to the list of existing submissions
                    ( { model | assignmentSubmissions = RemoteData.Success (submissions ++ [ newSubmission ]) }, Cmd.none )

                ( _, _ ) ->
                    -- In other cases do nothing
                    ( model, Cmd.none )

        Msgs.OnSubmitAssignmentFieldSubmissions assignmentSubmission ->
            let
                -- Have the submission id. Need to submit the assignmentSubmissionField tuples
                values =
                    valuesForSubmissionID assignmentSubmission.id model.assignmentFieldSubmissionInputs

                pendingRequest =
                    Dict.insert assignmentSubmission.assignment_slug RemoteData.Loading model.pendingAssignmentFieldSubmissionRequests
            in
            case model.currentUser of
                RemoteData.Success user ->
                    ( { model | pendingAssignmentFieldSubmissionRequests = pendingRequest }
                    , Cmd.batch
                        [ sendAssignmentFieldSubmissions user.jwt assignmentSubmission.assignment_slug values
                        ]
                    )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnUpdateAssignmentFieldSubmissionInput submissionID assignmentFieldSlug assignmentFieldValue ->
            let
                key =
                    ( submissionID, assignmentFieldSlug )

                newAfsi =
                    Dict.update key (\_ -> Just assignmentFieldValue) model.assignmentFieldSubmissionInputs
            in
            ( { model | assignmentFieldSubmissionInputs = newAfsi }, Cmd.none )

        Msgs.OnSubmitAssignmentFieldSubmissionsResponse assignmentSlug response ->
            -- todo, update the model.assignmentSubmissions
            case ( model.currentUser, model.assignmentSubmissions ) of
                ( RemoteData.Success user, RemoteData.Success submissions ) ->
                    case response of
                        RemoteData.Success newSubmissions ->
                            let
                                pfsrs =
                                    Dict.remove assignmentSlug model.pendingAssignmentFieldSubmissionRequests

                                cmd =
                                    Cmd.batch [ fetchAssignmentSubmissions user ]

                                newModel =
                                    { model | pendingAssignmentFieldSubmissionRequests = pfsrs, assignmentFieldSubmissionInputs = Dict.empty }
                            in
                            -- Lazy for right now - just re-fetch all assignment fiend submissions
                            ( newModel, cmd )

                        _ ->
                            ( model, Cmd.none )

                ( _, _ ) ->
                    ( model, Cmd.none )

        Msgs.OnFetchQuizSubmissions response ->
            onFetchQuizSubmissions model response

        Msgs.OnFetchQuizGrades response ->
            onFetchQuizGrades model response

        Msgs.OnFetchQuizGradeDistributions response ->
            onFetchQuizGradeDistributions model response

        Msgs.OnFetchAssignmentGrades response ->
            onFetchAssignmentGrades model response

        Msgs.OnFetchAssignmentGradeDistributions response ->
            onFetchAssignmentGradeDistributions model response

        Msgs.OnBeginQuiz quizID ->
            onBeginQuiz model quizID

        Msgs.OnBeginQuizComplete quizID response ->
            onBeginQuizComplete model quizID response

        Msgs.TakeQuiz quizID ->
            takeQuiz model quizID

        Msgs.OnFetchAssignmentGradeExceptions assignmentGradeExceptions ->
            ( { model | assignmentGradeExceptions = assignmentGradeExceptions }, Cmd.none )

        Msgs.OnFetchQuizGradeExceptions quizGradeExceptions ->
            ( { model | quizGradeExceptions = quizGradeExceptions }, Cmd.none )

        Msgs.OnFetchQuizQuestions quizID response ->
            ( { model | quizQuestions = Dict.insert quizID response model.quizQuestions }, Cmd.none )

        Msgs.OnFetchQuizAnswers quizID response ->
            ( { model | quizAnswers = Dict.insert quizID response model.quizAnswers }, Cmd.none )

        Msgs.OnSubmitQuizAnswers quizID quizQuestionOptionIds ->
            onSubmitQuizAnswers model quizID quizQuestionOptionIds

        Msgs.OnSubmitQuizAnswersComplete quizID response ->
            onSubmitQuizAnswersComplete model quizID response

        Msgs.OnToggleQuizQuestionOption optionID checked ->
            let
                newQOIs =
                    case checked of
                        True ->
                            Set.insert optionID model.quizQuestionOptionInputs

                        False ->
                            Set.remove optionID model.quizQuestionOptionInputs
            in
            ( { model | quizQuestionOptionInputs = newQOIs }, Cmd.none )

        Msgs.OnSSE sseMsgType ->
            case sseMsgType of
                Msgs.Noop ->
                    ( model, Cmd.none )

                Msgs.SSETableChange result ->
                    case result of
                        Ok routingKey ->
                            onSSETableChange routingKey ( { model | latestMessage = result }, Cmd.none )

                        _ ->
                            ( model, Cmd.none )

        Msgs.OnFetchEngagements response ->
            ( { model | engagements = response }, Cmd.none )

        Msgs.OnFetchUsers response ->
            ( { model | users = response }, Cmd.none )

        Msgs.OnChangeEngagement meetingSlug userID level ->
            let
                npses =
                    Dict.insert ( meetingSlug, userID ) RemoteData.Loading model.pendingSubmitEngagements

                newModel =
                    { model | pendingSubmitEngagements = npses }
            in
            case model.currentUser of
                RemoteData.Success user ->
                    ( newModel, submitEngagement user.jwt meetingSlug userID level )

                _ ->
                    ( model, Cmd.none )

        Msgs.OnSubmitEngagementResponse meetingSlug userID response ->
            let
                pses =
                    case response of
                        RemoteData.Success _ ->
                            Dict.remove ( meetingSlug, userID ) model.pendingSubmitEngagements

                        _ ->
                            Dict.insert ( meetingSlug, userID ) response model.pendingSubmitEngagements
            in
            ( { model | pendingSubmitEngagements = pses }, Cmd.none )

        Msgs.OnFetchTimeZone z ->
            let
                tz1 =
                    model.timeZone

                tz2 =
                    { tz1 | zone = z }
            in
            ( { model | timeZone = tz2 }, Cmd.none )

        Msgs.OnFetchTimeZoneName zoneName ->
            let
                tz1 =
                    model.timeZone

                tz2 =
                    { tz1 | zoneName = zoneName }
            in
            ( { model | timeZone = tz2 }, Cmd.none )


setSseAndDo : Model -> (SseAccess Msg -> ( SseAccess Msg, Cmd Msg )) -> ( Model, Cmd Msg )
setSseAndDo model f =
    let
        ( sse, cmd ) =
            f model.sse
    in
    ( { model | sse = sse }
    , cmd
    )


sseMessageDecoder : SSE.SsEvent -> Msg
sseMessageDecoder event =
    Msgs.OnSSE (Msgs.SSETableChange (decodeString string event.data))
