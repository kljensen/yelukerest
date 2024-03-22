module Quizzes.Views exposing (takeQuizView)

-- import Html.Attributes as Attrs

import Auth.Model exposing (CurrentUser)
import Common.Views exposing (longDateToString, stringDateDelta)
import Dict exposing (Dict)
import Html exposing (a)
import Html.Attributes as Attrs
import Html.Events as Events
import Json.Decode as Decode
import Markdown
import Models exposing (TimeZone)
import Msgs exposing (Msg)
import Quizzes.Model
    exposing
        ( Quiz
        , QuizAnswer
        , QuizGradeException
        , QuizOpenState(..)
        , QuizQuestion
        , QuizQuestionOption
        , QuizSubmission
        , SubmissionEditableState(..)
        , quizSubmitability
        , QuizType(..)
        )
import RemoteData exposing (WebData)
import Set
import Time exposing (Posix)


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


takeQuizView : WebData CurrentUser -> Maybe Posix -> TimeZone -> Int -> WebData (List QuizSubmission) -> WebData (List Quiz) -> Dict Int (WebData (List QuizQuestion)) -> Dict Int (WebData (List QuizAnswer)) -> WebData (List QuizGradeException) -> Dict Int (WebData (List QuizAnswer)) -> Set.Set Int -> Html.Html Msg
takeQuizView wdUser maybeDate timeZone quizID quizSubmissions quizzes quizQuestions quizAnswers wdQuizGradeExceptions pendingSubmitQuizzes selectedOptions =
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
    case ( wdUser, maybeDate ) of
        ( RemoteData.Failure _, _ ) ->
            Html.div [] [ Html.text "You must be logged in to see quizzes." ]

        ( RemoteData.Success user, Just currentDate ) ->
            case wdQuizData of
                RemoteData.Failure _ ->
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
                            showQuizForm user currentDate timeZone quizID daSub daQuiz data.questions data.answers wdQuizGradeExceptions thisPendingSubmitQuiz selectedOptions

                        ( _, Nothing ) ->
                            Html.div [] [ Html.text "Error - no such quiz." ]

                        ( Nothing, _ ) ->
                            Html.div [] [ Html.text "Error - you've not yet started this quiz." ]

                RemoteData.NotAsked ->
                    Html.div [] [ Html.text "Need to load data to view this page!" ]

        ( _, _ ) ->
            Html.div [] [ Html.text "Loading..." ]


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
        RemoteData.Failure _ ->
            let
                errorMessage =
                    "HTTP error!"
            in
            Html.div [ Attrs.class "red" ] [ Html.text ("Error submitting the quiz! " ++ errorMessage) ]

        _ ->
            Html.text ""


showQuizForm : CurrentUser -> Posix -> TimeZone -> Int -> QuizSubmission -> Quiz -> List QuizQuestion -> List QuizAnswer -> WebData (List QuizGradeException) -> WebData a -> Set.Set Int -> Html.Html Msg
showQuizForm user currentDate timeZone quizID quizSubmission quiz quizQuestions quizAnswers wdQuizGradeExceptions pendingSubmit selectedOptions =
    let
        quizQuestionOptionIds =
            quizQuestions
                |> List.concatMap .options
                |> List.map .id

        quizAnswerSet =
            quizAnswers
                |> List.map .quiz_question_option_id
                |> Set.fromList

        maybeException =
            case wdQuizGradeExceptions of
                RemoteData.Success exceptions ->
                    exceptions
                        |> List.filter (\e -> e.quiz_id == quiz.id && e.user_id == user.id)
                        |> List.head

                _ ->
                    Nothing
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
        (List.map (showQuestion quizAnswerSet selectedOptions) quizQuestions
            ++ [ showSubmitButton currentDate timeZone quiz quizSubmission maybeException pendingSubmit
               ]
        )

showSubmitButton : Posix -> TimeZone -> Quiz -> QuizSubmission -> Maybe QuizGradeException -> WebData a -> Html.Html Msg
showSubmitButton currentDate timeZone quiz quizSubmission maybeException pendingSubmit =
    let
        quizType =
            quizSubmitability currentDate quiz (Just quizSubmission) maybeException
    in
    case quizType of 
        Offline ->
            Html.div [] [ Html.text "This quiz is offline." ]
        Online( BeforeQuizOpen, _ ) ->
            Html.div [] [ Html.text "This quiz is not open yet." ]

        Online( QuizOpen, EditableSubmission submission ) ->
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
                            ++ " and must be submitted prior to "
                            ++ longDateToString submission.closed_at timeZone
                            ++ ". You have roughly "
                            ++ stringDateDelta submission.closed_at currentDate
                            ++ " left."
                            ++ (case maybeException of
                                    Just _ ->
                                        " (That includes your quiz grade exception/extension.)"

                                    Nothing ->
                                        ""
                               )
                        )
                    ]
                , showSubmitError pendingSubmit
                ]

        Online( _, _ ) ->
            Html.div [] [ Html.text "This quiz is now closed and can no longer be submitted." ]


showQuestion : Set.Set Int -> Set.Set Int -> QuizQuestion -> Html.Html Msg
showQuestion savedAnswers selectedOptions quizQuestion =
    Html.fieldset []
        ( [
            Markdown.toHtml [] quizQuestion.body
            , Html.em [] [Html.text (if quizQuestion.multiple_correct then "Select all that apply" else "")]
        ] ++
            List.map (showQuestionOption quizQuestion savedAnswers selectedOptions) quizQuestion.options
        )


showQuestionOption : QuizQuestion -> Set.Set Int -> Set.Set Int -> QuizQuestionOption -> Html.Html Msg
showQuestionOption quizQuestion selectedAnswers selectedOptions option =
    let
        selectionIndicator =
            if Set.member option.id selectedAnswers then
                Html.span [ Attrs.class "saved-quiz-option" ] [ Html.text "SAVED" ]

            else
                Html.text ""
        inputType =
            if quizQuestion.multiple_correct then
                "checkbox"
            else
                "radio"
        onCheckMsg =
             if quizQuestion.multiple_correct then
                Msgs.OnToggleQuizQuestionOption option.id
             else
                Msgs.OnSelectQuizQuestionOption option.id (List.map .id quizQuestion.options)
    in
    Html.div [Attrs.class "quiz-question-option"]
        [ Html.input
            [ Attrs.name quizQuestion.slug
            , Attrs.id ("option-" ++ String.fromInt option.id)
            , Attrs.type_ inputType
            , Attrs.checked (Set.member option.id selectedOptions)
            , Events.onCheck onCheckMsg
            ]
            []
        , Html.label
            [ Attrs.for ("option-" ++ String.fromInt option.id)
            ]
            [ Markdown.toHtml [] option.body ]
        , selectionIndicator
        ]
