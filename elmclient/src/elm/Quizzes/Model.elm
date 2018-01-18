module Quizzes.Model exposing (Quiz, QuizSubmission, quizSubmissionDecoder, quizzesDecoder)

import Date exposing (Date)
import Json.Decode as Decode
import Json.Decode.Extra exposing (date)
import Json.Decode.Pipeline exposing (decode, required)


type alias Quiz =
    { id : Int
    , meeting_id : Int
    , points_possible : Int
    , is_draft : Bool
    , duration : String
    , open_at : Date
    , closed_at : Date
    , is_open : Bool
    , created_at : Date
    , updated_at : Date
    }


quizzesDecoder : Decode.Decoder (List Quiz)
quizzesDecoder =
    Decode.list quizDecoder


quizDecoder : Decode.Decoder Quiz
quizDecoder =
    decode Quiz
        |> required "id" Decode.int
        |> required "meeting_id" Decode.int
        |> required "points_possible" Decode.int
        |> required "is_draft" Decode.bool
        |> required "duration" Decode.string
        |> required "open_at" Json.Decode.Extra.date
        |> required "closed_at" Json.Decode.Extra.date
        |> required "is_open" Decode.bool
        |> required "created_at" Json.Decode.Extra.date
        |> required "updated_at" Json.Decode.Extra.date



-- ----------------
-- Quiz submissions
-- ----------------


type alias QuizSubmission =
    { quiz_id : Int
    , user_id : Int
    , created_at : Date
    , updated_at : Date
    }


quizSubmissionsDecoder : Decode.Decoder (List QuizSubmission)
quizSubmissionsDecoder =
    Decode.list quizSubmissionDecoder


quizSubmissionDecoder : Decode.Decoder QuizSubmission
quizSubmissionDecoder =
    decode QuizSubmission
        |> required "quiz_id" Decode.int
        |> required "user_id" Decode.int
        |> required "created_at" Json.Decode.Extra.date
        |> required "updated_at" Json.Decode.Extra.date



-- Encoder not yet needed
