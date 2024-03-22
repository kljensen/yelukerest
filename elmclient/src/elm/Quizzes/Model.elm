module Quizzes.Model exposing
    ( Quiz
    , QuizAnswer
    , QuizGrade
    , QuizGradeDistribution
    , QuizGradeException
    , QuizOpenState(..)
    , QuizQuestion
    , QuizQuestionOption
    , QuizSubmission
    , QuizType(..)
    , SubmissionEditableState(..)
    , quizAnswersDecoder
    , quizGradeDistributionsDecoder
    , quizGradeExceptionDecoder
    , quizGradeExceptionsDecoder
    , quizGradesDecoder
    , quizQuestionsDecoder
    , quizSubmissionDecoder
    , quizSubmissionsDecoder
    , quizSubmitability
    , quizzesDecoder
    , updateIntSet
    )

import Set exposing (Set)
import Common.Comparisons exposing (dateIsLessThan)
import Json.Decode as Decode exposing (Decoder)
import Json.Decode.Extra
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
    , is_offline : Bool
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
        |> required "is_offline" Decode.bool



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

type QuizType
    =
    Online (QuizOpenState, SubmissionEditableState)
    | Offline


quizSubmitability : Posix -> Quiz -> Maybe QuizSubmission -> Maybe QuizGradeException -> QuizType
quizSubmitability currentDate quiz maybeQuizSubmission maybeException =
    let
        quizOpenState =
            if dateIsLessThan currentDate quiz.open_at then
                BeforeQuizOpen

            else if dateIsLessThan quiz.closed_at currentDate then
                case maybeException of
                    Just exception ->
                        if dateIsLessThan currentDate exception.closed_at then
                            QuizOpen

                        else
                            AfterQuizClosed

                    Nothing ->
                        AfterQuizClosed

            else if quiz.is_draft then
                QuizIsDraft

            else
                QuizOpen

        submissionEditableState =
            case maybeQuizSubmission of
                Just quizSubmission ->
                    if dateIsLessThan currentDate quizSubmission.closed_at then
                        EditableSubmission quizSubmission
                    else
                        NotEditableSubmission quizSubmission

                Nothing ->
                    NoSubmission
    in
    if quiz.is_offline then
        Offline
    else
        Online ( quizOpenState, submissionEditableState )


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
    , slug : String
    , multiple_correct : Bool
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
        |> required "slug" Decode.string
        |> required "multiple_correct" Decode.bool
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


type alias QuizGradeException =
    { id : Int
    , quiz_id : Int
    , user_id : Int
    , fractional_credit : Float
    , closed_at : Posix
    , created_at : Posix
    , updated_at : Posix
    }


quizGradeExceptionDecoder : Decode.Decoder QuizGradeException
quizGradeExceptionDecoder =
    Decode.succeed QuizGradeException
        |> required "id" Decode.int
        |> required "quiz_id" Decode.int
        |> required "user_id" Decode.int
        |> required "fractional_credit" Decode.float
        |> required "closed_at" Json.Decode.Extra.datetime
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime


quizGradeExceptionsDecoder : Decode.Decoder (List QuizGradeException)
quizGradeExceptionsDecoder =
    Decode.list quizGradeExceptionDecoder

{-|
    Updates a set of integers, first removing a list of
    values and then adding a list of values.
-}
updateIntSet : (Set Int) -> (List Int) -> (List Int) -> (Set Int)
updateIntSet theSet toRemove toAdd =
    Set.diff theSet (Set.fromList toRemove)
    |> Set.union (Set.fromList toAdd)