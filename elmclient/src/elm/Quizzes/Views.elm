module Quizzes.Views exposing (takeQuizView)
import Html exposing (Html, a, div, h1, text)
-- import Html.Attributes as Attrs
import Msgs exposing (Msg)
import RemoteData exposing (WebData)
import Quizzes.Model exposing (QuizSubmission, Quiz)

takeQuizView : Int ->  WebData (List QuizSubmission) -> WebData (List Quiz) -> Html.Html Msg
takeQuizView quizSubmissionID quizSubmissions quiz=
    Html.div [] [Html.text "This is the quiz taking page"]