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
        , QuizQuestion
        , QuizQuestionOption
        , QuizSubmission
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


takeQuizView : Int -> WebData (List QuizSubmission) -> WebData (List Quiz) -> Dict Int (WebData (List QuizQuestion)) -> Dict Int (WebData (List QuizAnswer)) -> Html.Html Msg
takeQuizView quizID quizSubmissions quizzes quizQuestions quizAnswers =
    let
        theseQuizQuestions =
            getOrNotAsked quizID quizQuestions

        theseQuizAnswers =
            getOrNotAsked quizID quizAnswers

        data =
            merge4 quizSubmissions quizzes theseQuizQuestions theseQuizAnswers
    in
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
                    showQuizForm quizID daSub daQuiz qq qa

                ( _, Nothing ) ->
                    Html.div [] [ Html.text "Error - you've not yet started this quiz." ]

                ( Nothing, _ ) ->
                    Html.div [] [ Html.text "Error - no such quiz." ]

        RemoteData.NotAsked ->
            Html.div [] [ Html.text "Need to load data to view this page!" ]


showQuizForm : Int -> QuizSubmission -> Quiz -> List QuizQuestion -> List QuizAnswer -> Html.Html Msg
showQuizForm quizID quizSubmission quiz quizQuestions quizAnswers =
    Html.form
        [ Events.onWithOptions
            "submit"
            { preventDefault = True, stopPropagation = False }
            (Decode.succeed (Msgs.OnSubmitQuizAnswers quizID))
        ]
        (List.map (showQuestion quizAnswers) quizQuestions
            ++ [ Html.button [ Attrs.class "btn btn-primary" ] [ Html.text "Submit" ] ]
        )


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
