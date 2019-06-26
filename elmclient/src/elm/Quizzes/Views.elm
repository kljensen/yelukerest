module Quizzes.Views exposing (takeQuizView)

-- import Html.Attributes as Attrs

import Dict exposing (Dict)
import Html exposing (Html, a, div, h1, text)
import Html.Attributes as Attrs
import Html.Events as Events
import Json.Decode as Decode
import Markdown
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( Quiz
        , QuizAnswer
        , QuizOpenState(..)
        , QuizQuestion
        , QuizQuestionOption
        , QuizSubmission
        , SubmissionEditableState(..)
        , quizSubmitability
        )
import RemoteData exposing (WebData)
import Set
import Time exposing (Posix, utc)


getOrNotAsked : comparable -> Dict comparable (WebData b) -> WebData b
getOrNotAsked x y =
    case Dict.get x y of
        Just z ->
            z

        Nothing ->
            RemoteData.NotAsked


filterGet : List a -> (a -> Bool) -> Maybe a
filterGet x f =
    x
        |> List.filter f
        |> List.head


type alias QuizViewData =
    { submissions : List QuizSubmission
    , quizzes : List Quiz
    , questions : List QuizQuestion
    , answers : List QuizAnswer
    }


makeQuizViewData : List QuizSubmission -> List Quiz -> List QuizQuestion -> List QuizAnswer -> QuizViewData
makeQuizViewData quizSubmissions quizzes theseQuizQuestions theseQuizAnswers =
    { submissions = quizSubmissions
    , quizzes = quizzes
    , questions = theseQuizQuestions
    , answers = theseQuizAnswers
    }


mergeQuizViewData : WebData (List QuizSubmission) -> WebData (List Quiz) -> WebData (List QuizQuestion) -> WebData (List QuizAnswer) -> WebData QuizViewData
mergeQuizViewData quizSubmissions quizzes theseQuizQuestions theseQuizAnswers =
    RemoteData.map makeQuizViewData quizSubmissions
        |> RemoteData.andMap quizzes
        |> RemoteData.andMap theseQuizQuestions
        |> RemoteData.andMap theseQuizAnswers



-- merge4 :
--     WebData a
--     -> WebData b
--     -> WebData c
--     -> WebData d
--     -> WebData ( a, b, c, d )
-- merge4 a b c d =
--     RemoteData.map (\a b c d -> ( a, b, c, d )) a
--         |> RemoteData.andMap b
--         |> RemoteData.andMap c
--         |> RemoteData.andMap d


takeQuizView : Maybe Posix -> Int -> WebData (List QuizSubmission) -> WebData (List Quiz) -> Dict Int (WebData (List QuizQuestion)) -> Dict Int (WebData (List QuizAnswer)) -> Dict Int (WebData (List QuizAnswer)) -> Html.Html Msg
takeQuizView maybeDate quizID quizSubmissions quizzes quizQuestions quizAnswers pendingSubmitQuizzes =
    let
        theseQuizQuestions =
            getOrNotAsked quizID quizQuestions

        theseQuizAnswers =
            getOrNotAsked quizID quizAnswers

        thisPendingSubmitQuiz =
            getOrNotAsked quizID pendingSubmitQuizzes

        wdQuizData =
            mergeQuizViewData quizSubmissions quizzes theseQuizQuestions theseQuizAnswers
    in
    case maybeDate of
        Nothing ->
            Html.div [] [ Html.text "Loading..." ]

        Just currentDate ->
            case wdQuizData of
                RemoteData.Failure error ->
                    Html.div [] [ Html.text "HTTP Error!" ]

                RemoteData.Loading ->
                    Html.div [] [ Html.text "Loading..." ]

                RemoteData.Success data ->
                    let
                        sub =
                            filterGet data.submissions (\a -> a.quiz_id == quizID)

                        quiz =
                            filterGet data.quizzes (\a -> a.id == quizID)
                    in
                    case ( sub, quiz ) of
                        ( Just daSub, Just daQuiz ) ->
                            showQuizForm currentDate quizID daSub daQuiz data.questions data.answers thisPendingSubmitQuiz

                        ( _, Nothing ) ->
                            Html.div [] [ Html.text "Error - you've not yet started this quiz." ]

                        ( Nothing, _ ) ->
                            Html.div [] [ Html.text "Error - no such quiz." ]

                RemoteData.NotAsked ->
                    Html.div [] [ Html.text "Need to load data to view this page!" ]


isLoading : WebData a -> Bool
isLoading x =
    case x of
        RemoteData.Loading ->
            True

        _ ->
            False


showSubmitError : WebData a -> Html.Html Msg
showSubmitError x =
    case x of
        RemoteData.Failure e ->
            let
                errorMessage =
                    "HTTP error!"
            in
            Html.div [ Attrs.class "red" ] [ Html.text ("Error submitting the quiz! " ++ errorMessage) ]

        _ ->
            Html.text ""


showQuizForm : Posix -> Int -> QuizSubmission -> Quiz -> List QuizQuestion -> List QuizAnswer -> WebData a -> Html.Html Msg
showQuizForm currentDate quizID quizSubmission quiz quizQuestions quizAnswers pendingSubmit =
    let
        quizQuestionOptionIds =
            quizQuestions
                |> List.concatMap .options
                |> List.map .id

        quizAnswerSet =
            quizAnswers
                |> List.map .quiz_question_option_id
                |> Set.fromList
    in
    Html.form
        [ Events.custom
            "submit"
            (Decode.succeed
                { preventDefault = True
                , stopPropagation = False
                , message = Msgs.OnSubmitQuizAnswers quizID quizQuestionOptionIds
                }
            )
        ]
        (List.map (showQuestion quizAnswerSet) quizQuestions
            ++ [ showSubmitButton currentDate quiz quizSubmission pendingSubmit
               ]
        )


toUtcString : Time.Posix -> String
toUtcString time =
    String.fromInt (Time.toHour utc time)
        ++ ":"
        ++ String.fromInt (Time.toMinute utc time)
        ++ ":"
        ++ String.fromInt (Time.toSecond utc time)
        ++ " (UTC)"


showSubmitButton : Posix -> Quiz -> QuizSubmission -> WebData a -> Html.Html Msg
showSubmitButton currentDate quiz quizSubmission pendingSubmit =
    let
        submitablity =
            quizSubmitability currentDate quiz (Just quizSubmission)
    in
    case submitablity of
        ( BeforeQuizOpen, _ ) ->
            Html.div [] [ Html.text "This quiz is not open yet." ]

        ( QuizOpen, EditableSubmission submission ) ->
            Html.div []
                [ Html.p []
                    [ Html.button
                        [ Attrs.class "btn btn-primary"
                        , Attrs.disabled (isLoading pendingSubmit)
                        ]
                        [ Html.text "Save Answers" ]
                    ]
                , Html.div []
                    [ Html.text
                        ("This quiz has a duration of "
                            ++ quiz.duration
                            ++ " and a close date of "
                            ++ toUtcString quiz.closed_at
                            ++ ".  You have roughly "
                            ++ dateDeltaToString (dateDelta submission.closed_at currentDate)
                            ++ " left."
                        )
                    ]
                , showSubmitError pendingSubmit
                ]

        ( _, _ ) ->
            Html.div [] [ Html.text "This quiz is now closed and can no longer be submitted." ]


showQuestion : Set.Set Int -> QuizQuestion -> Html.Html Msg
showQuestion selectedAnswers quizQuestion =
    Html.fieldset []
        ([ Markdown.toHtml [] quizQuestion.body ]
            ++ List.map (showQuestionOption selectedAnswers) quizQuestion.options
        )


showQuestionOption : Set.Set Int -> QuizQuestionOption -> Html.Html Msg
showQuestionOption selectedAnswers option =
    let
        selectionIndicator =
            if Set.member option.id selectedAnswers then
                Html.span [ Attrs.class "saved-quiz-option" ] [ Html.text "SAVED" ]

            else
                Html.text ""
    in
    Html.div []
        [ Html.input
            [ Attrs.name (String.fromInt option.id)
            , Attrs.id ("option-" ++ String.fromInt option.id)
            , Attrs.type_ "checkbox"
            , Events.onCheck (Msgs.OnToggleQuizQuestionOption option.id)
            ]
            []
        , Html.label
            [ Attrs.for ("option-" ++ String.fromInt option.id)
            ]
            [ Html.text option.body
            , selectionIndicator
            ]
        ]


dateDelta : Posix -> Posix -> Int
dateDelta d2 d1 =
    Time.posixToMillis d2 - Time.posixToMillis d1


dateDeltaToString : Int -> String
dateDeltaToString d =
    let
        msInSecond =
            1000

        msInMinute =
            60 * msInSecond

        msInHour =
            60 * msInMinute

        msInDay =
            24 * msInHour

        days =
            d // msInDay

        d2 =
            d - (days * msInDay)

        hours =
            d2 // msInHour

        d3 =
            d2 - (hours * msInHour)

        minutes =
            d3 // msInMinute

        d4 =
            d3 - (minutes * msInMinute)

        seconds =
            d4 // msInSecond
    in
    case days > 0 of
        True ->
            String.fromInt days
                ++ " days and "
                ++ String.fromInt hours
                ++ " hours"

        False ->
            [ hours, minutes, seconds ]
                |> List.map String.fromInt
                |> List.map (String.padLeft 2 '0')
                |> String.join ":"
