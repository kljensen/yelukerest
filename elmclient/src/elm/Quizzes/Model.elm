module Quizzes.Model exposing
    ( Quiz
    , QuizAnswer
    , QuizGrade
    , QuizGradeDistribution
    , QuizOpenState(..)
    , QuizQuestion
    , QuizQuestionOption
    , QuizSubmission
    , SubmissionEditableState(..)
    , quizAnswersDecoder
    , quizGradeDistributionsDecoder
    , quizGradesDecoder
    , quizQuestionsDecoder
    , quizSubmissionDecoder
    , quizSubmissionsDecoder
    , quizSubmitability
    , quizzesDecoder
    )

import Common.Comparisons exposing (dateIsLessThan)
import Json.Decode as Decode exposing (Decoder)
import Json.Decode.Extra exposing (datetime)
import Json.Decode.Pipeline exposing (required)
import Time exposing (Posix)


type alias Quiz =
    { id : Int
    , meeting_slug : String
    , points_possible : Int
    , is_draft : Bool
    , duration : String
    , open_at : Posix
    , closed_at : Posix
    , is_open : Bool
    , created_at : Posix
    , updated_at : Posix
    }


quizzesDecoder : Decode.Decoder (List Quiz)
quizzesDecoder =
    Decode.list quizDecoder


quizDecoder : Decoder Quiz
quizDecoder =
    Decode.succeed Quiz
        |> required "id" Decode.int
        |> required "meeting_slug" Decode.string
        |> required "points_possible" Decode.int
        |> required "is_draft" Decode.bool
        |> required "duration" Decode.string
        |> required "open_at" Json.Decode.Extra.datetime
        |> required "closed_at" Json.Decode.Extra.datetime
        |> required "is_open" Decode.bool
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime



-- ----------------
-- Quiz submissions
-- ----------------


type QuizOpenState
    = BeforeQuizOpen
    | QuizOpen
    | QuizIsDraft
    | AfterQuizClosed


type SubmissionEditableState
    = EditableSubmission QuizSubmission
    | NotEditableSubmission QuizSubmission
    | NoSubmission


quizSubmitability : Posix -> Quiz -> Maybe QuizSubmission -> ( QuizOpenState, SubmissionEditableState )
quizSubmitability currentDate quiz maybeQuizSubmission =
    let
        quizOpenState =
            if dateIsLessThan currentDate quiz.open_at then
                BeforeQuizOpen

            else if dateIsLessThan quiz.closed_at currentDate then
                AfterQuizClosed

            else if quiz.is_draft then
                QuizIsDraft

            else
                QuizOpen

        submissionEditableState =
            case maybeQuizSubmission of
                Just quizSubmission ->
                    case dateIsLessThan currentDate quizSubmission.closed_at of
                        True ->
                            EditableSubmission quizSubmission

                        False ->
                            NotEditableSubmission quizSubmission

                Nothing ->
                    NoSubmission
    in
    ( quizOpenState, submissionEditableState )


type alias QuizSubmission =
    { quiz_id : Int
    , user_id : Int
    , closed_at : Posix
    , is_open : Bool
    , created_at : Posix
    , updated_at : Posix
    }


quizSubmissionsDecoder : Decode.Decoder (List QuizSubmission)
quizSubmissionsDecoder =
    Decode.list quizSubmissionDecoder


quizSubmissionDecoder : Decode.Decoder QuizSubmission
quizSubmissionDecoder =
    Decode.succeed QuizSubmission
        |> required "quiz_id" Decode.int
        |> required "user_id" Decode.int
        |> required "closed_at" Json.Decode.Extra.datetime
        |> required "is_open" Decode.bool
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime



-- Encoder not yet needed


type alias QuizQuestion =
    { id : Int
    , body : String
    , options : List QuizQuestionOption
    }


type alias QuizQuestionOption =
    { id : Int
    , body : String
    }


type alias QuizAnswer =
    { user_id : Int
    , quiz_question_option_id : Int
    , quiz_id : Int
    }


quizAnswerDecoder : Decode.Decoder QuizAnswer
quizAnswerDecoder =
    Decode.succeed QuizAnswer
        |> required "user_id" Decode.int
        |> required "quiz_question_option_id" Decode.int
        |> required "quiz_id" Decode.int


quizAnswersDecoder : Decode.Decoder (List QuizAnswer)
quizAnswersDecoder =
    Decode.list quizAnswerDecoder


quizQuestionDecoder : Decode.Decoder QuizQuestion
quizQuestionDecoder =
    Decode.succeed QuizQuestion
        |> required "id" Decode.int
        |> required "body" Decode.string
        |> required "options" quizQuestionOptionsDecoder


quizQuestionsDecoder : Decode.Decoder (List QuizQuestion)
quizQuestionsDecoder =
    Decode.list quizQuestionDecoder


quizQuestionOptionDecoder : Decode.Decoder QuizQuestionOption
quizQuestionOptionDecoder =
    Decode.succeed QuizQuestionOption
        |> required "id" Decode.int
        |> required "body" Decode.string


quizQuestionOptionsDecoder : Decode.Decoder (List QuizQuestionOption)
quizQuestionOptionsDecoder =
    Decode.list quizQuestionOptionDecoder


type alias QuizGrade =
    { quiz_id : Int
    , points : Float
    , points_possible : Int
    , user_id : Int
    , created_at : Posix
    , updated_at : Posix
    }


quizGradeDecoder : Decode.Decoder QuizGrade
quizGradeDecoder =
    Decode.succeed QuizGrade
        |> required "quiz_id" Decode.int
        |> required "points" Decode.float
        |> required "points_possible" Decode.int
        |> required "user_id" Decode.int
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime


quizGradesDecoder : Decode.Decoder (List QuizGrade)
quizGradesDecoder =
    Decode.list quizGradeDecoder


type alias QuizGradeDistribution =
    { quiz_id : Int
    , count : Int
    , average : Float
    , min : Float
    , max : Float
    , points_possible : Int
    , stddev : Float
    , grades : List Float
    }


quizGradeDistributionDecoder : Decode.Decoder QuizGradeDistribution
quizGradeDistributionDecoder =
    Decode.succeed QuizGradeDistribution
        |> required "quiz_id" Decode.int
        |> required "count" Decode.int
        |> required "average" Decode.float
        |> required "min" Decode.float
        |> required "max" Decode.float
        |> required "points_possible" Decode.int
        |> required "stddev" Decode.float
        |> required "grades" (Decode.list Decode.float)


quizGradeDistributionsDecoder : Decode.Decoder (List QuizGradeDistribution)
quizGradeDistributionsDecoder =
    Decode.list quizGradeDistributionDecoder
