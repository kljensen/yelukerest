module Quizzes.Model exposing
    ( Quiz
    , QuizArtifact
    , QuizGrade
    , QuizGradeDistribution
    , QuizSubmission
    , paperQuizStatusText
    , quizArtifactsDecoder
    , quizGradeDistributionsDecoder
    , quizGradesDecoder
    , quizSubmissionDecoder
    , quizSubmissionsDecoder
    , quizzesDecoder
    )

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


paperQuizStatusText : String
paperQuizStatusText =
    "There is an in-person quiz for this meeting."


-- ----------------
-- Quiz submissions
-- ----------------

type alias QuizSubmission =
    { quiz_id : Int
    , user_id : Int
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
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime


-- --------------
-- Quiz artifacts
-- --------------


type alias QuizArtifact =
    { id : Int
    , user_id : Int
    , quiz_id : Maybe Int
    , slug : String
    , title : String
    , description : String
    , url : String
    , storage_uri : Maybe String
    , content_type : Maybe String
    , content_length : Maybe Int
    , checksum_sha256 : Maybe String
    , is_user_visible : Bool
    , created_at : Posix
    , updated_at : Posix
    }


quizArtifactsDecoder : Decode.Decoder (List QuizArtifact)
quizArtifactsDecoder =
    Decode.list quizArtifactDecoder


quizArtifactDecoder : Decode.Decoder QuizArtifact
quizArtifactDecoder =
    Decode.succeed QuizArtifact
        |> required "id" Decode.int
        |> required "user_id" Decode.int
        |> required "quiz_id" (Decode.nullable Decode.int)
        |> required "slug" Decode.string
        |> required "title" Decode.string
        |> required "description" Decode.string
        |> required "url" Decode.string
        |> required "storage_uri" (Decode.nullable Decode.string)
        |> required "content_type" (Decode.nullable Decode.string)
        |> required "content_length" (Decode.nullable Decode.int)
        |> required "checksum_sha256" (Decode.nullable Decode.string)
        |> required "is_user_visible" Decode.bool
        |> required "created_at" Json.Decode.Extra.datetime
        |> required "updated_at" Json.Decode.Extra.datetime



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
