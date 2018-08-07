module Quizzes.Views exposing (takeQuizView)

-- import Html.Attributes as Attrs

import Dict exposing (Dict)
import Html exposing (Html, a, div, h1, text)
import Msgs exposing (Msg)
import Quizzes.Model exposing (Quiz, QuizAnswer, QuizQuestion, QuizSubmission)
import RemoteData exposing (WebData)


merge4 :
    RemoteData.RemoteData e a
    -> RemoteData.RemoteData e b
    -> RemoteData.RemoteData e c
    -> RemoteData.RemoteData e d
    -> RemoteData.RemoteData e ( a, b, c, d )
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
    Html.div [] [ Html.text "Going to show quiz form here!" ]
