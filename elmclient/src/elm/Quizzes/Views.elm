module Quizzes.Views exposing (takeQuizView)

-- import Html.Attributes as Attrs

import Date
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


merge4 :
    WebData a
    -> WebData b
    -> WebData c
    -> WebData d
    -> WebData ( a, b, c, d )
merge4 a b c d =
    RemoteData.map (,,,) a
        |> RemoteData.andMap b
        |> RemoteData.andMap c
        |> RemoteData.andMap d


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


takeQuizView : Maybe Date.Date -> Int -> WebData (List QuizSubmission) -> WebData (List Quiz) -> Dict Int (WebData (List QuizQuestion)) -> Dict Int (WebData (List QuizAnswer)) -> Dict Int (WebData (List QuizAnswer)) -> Html.Html Msg
takeQuizView maybeDate quizID quizSubmissions quizzes quizQuestions quizAnswers pendingSubmitQuizzes =
    let
        theseQuizQuestions =
            getOrNotAsked quizID quizQuestions

        theseQuizAnswers =
            getOrNotAsked quizID quizAnswers

        thisPendingSubmitQuiz =
            getOrNotAsked quizID pendingSubmitQuizzes

        data =
            merge4 quizSubmissions quizzes theseQuizQuestions theseQuizAnswers
    in
    case maybeDate of
        Nothing ->
            Html.div [] [ Html.text "Loading..." ]

        Just currentDate ->
            case data of
                RemoteData.Failure error ->
                    Html.div [] [ Html.text (toString error) ]

                RemoteData.Loading ->
                    Html.div [] [ Html.text "Loading..." ]

                RemoteData.Success ( qs, q, qq, qa ) ->
                    let
                        sub =
                            filterGet qs (\a -> a.quiz_id == quizID)

                        quiz =
                            filterGet q (\a -> a.id == quizID)
                    in
                    case ( sub, quiz ) of
                        ( Just daSub, Just daQuiz ) ->
                            showQuizForm currentDate quizID daSub daQuiz qq qa thisPendingSubmitQuiz

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
                    toString e
            in
            Html.div [ Attrs.class "red" ] [ Html.text ("Error submitting the quiz! " ++ errorMessage) ]

        _ ->
            Html.text ""


showQuizForm : Date.Date -> Int -> QuizSubmission -> Quiz -> List QuizQuestion -> List QuizAnswer -> WebData a -> Html.Html Msg
showQuizForm currentDate quizID quizSubmission quiz quizQuestions quizAnswers pendingSubmit =
    let
        quizQuestionOptionIds =
            quizQuestions
                |> List.concatMap .options
                |> List.map .id
    in
    Html.form
        [ Events.onWithOptions
            "submit"
            { preventDefault = True, stopPropagation = False }
            (Decode.succeed (Msgs.OnSubmitQuizAnswers quizID quizQuestionOptionIds))
        ]
        (List.map (showQuestion quizAnswers) quizQuestions
            ++ [ showSubmitButton currentDate quiz quizSubmission pendingSubmit
               ]
        )


showSubmitButton : Date.Date -> Quiz -> QuizSubmission -> WebData a -> Html.Html Msg
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
                [ Html.button
                    [ Attrs.class "btn btn-primary"
                    , Attrs.disabled (isLoading pendingSubmit)
                    ]
                    [ Html.text "Save Answers" ]
                , showSubmitError pendingSubmit
                ]

        ( _, _ ) ->
            Html.div [] [ Html.text "This quiz is now closed and can no longer be submitted." ]


showQuestion : List QuizAnswer -> QuizQuestion -> Html.Html Msg
showQuestion quizAnswers quizQuestion =
    Html.fieldset []
        ([ Markdown.toHtml [] quizQuestion.body ]
            ++ List.map showQuestionOption quizQuestion.options
        )


showQuestionOption : QuizQuestionOption -> Html.Html Msg
showQuestionOption option =
    Html.div []
        [ Html.input
            [ Attrs.name (toString option.id)
            , Attrs.id ("option-" ++ toString option.id)
            , Attrs.type_ "checkbox"
            , Events.onCheck (Msgs.OnToggleQuizQuestionOption option.id)
            ]
            []
        , Html.label
            [ Attrs.for ("option-" ++ toString option.id)
            ]
            [ Html.text option.body ]

        -- , Html.text ""
        ]



-- Html.div []
--     [ Html.input
--         [ Attrs.name (toString option.id)
--         , Attrs.type_ "checkbox"
--         ]
--         []
--     , Html.label [] [ Html.text option.body ]
--     ]
