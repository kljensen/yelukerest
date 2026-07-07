module QuizzesModelTest exposing (tests)

import Expect
import Json.Decode as Decode
import Quizzes.Model exposing (paperQuizStatusText, quizArtifactsDecoder, quizSubmissionDecoder, quizzesDecoder)
import Test exposing (Test, describe, test)
import Time


tests : Test
tests =
    describe "Quizzes.Model"
        [ test "decodes paper quiz metadata" <|
            \_ ->
                Decode.decodeString quizzesDecoder paperQuizJson
                    |> Expect.equal
                        (Ok
                            [ { id = 1
                              , meeting_slug = "week-1"
                              , points_possible = 5
                              , is_draft = False
                              , duration = "00:05:00"
                              , open_at = millis 1000
                              , closed_at = millis 2000
                              , is_open = False
                              , created_at = millis 0
                              , updated_at = millis 0
                              , is_offline = True
                              }
                            ]
                        )
        , test "keeps quiz submission decoding for read-only imported paper quiz status" <|
            \_ ->
                Decode.decodeString quizSubmissionDecoder quizSubmissionJson
                    |> Expect.equal
                        (Ok
                            { quiz_id = 1
                            , user_id = 42
                            , closed_at = millis 2000
                            , is_open = False
                            , created_at = millis 0
                            , updated_at = millis 0
                            }
                        )
        , test "decodes student artifact metadata with nullable quiz linkage" <|
            \_ ->
                Decode.decodeString quizArtifactsDecoder artifactJson
                    |> Expect.equal
                        (Ok
                            [ { id = 1
                              , user_id = 42
                              , quiz_id = Just 1
                              , slug = "quiz-1-scan"
                              , title = "Quiz 1 scan"
                              , description = "Scanned quiz"
                              , url = "https://example.com/quiz-1.pdf"
                              , storage_uri = Just "s3://course-artifacts/quiz-1.pdf"
                              , content_type = Just "application/pdf"
                              , content_length = Just 123
                              , checksum_sha256 = Just "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                              , is_user_visible = True
                              , created_at = millis 0
                              , updated_at = millis 0
                              }
                            , { id = 2
                              , user_id = 42
                              , quiz_id = Nothing
                              , slug = "feedback"
                              , title = "Feedback"
                              , description = ""
                              , url = "https://example.com/feedback.pdf"
                              , storage_uri = Nothing
                              , content_type = Nothing
                              , content_length = Nothing
                              , checksum_sha256 = Nothing
                              , is_user_visible = True
                              , created_at = millis 0
                              , updated_at = millis 0
                              }
                            ]
                        )
        , test "uses paper-only meeting quiz status text" <|
            \_ ->
                paperQuizStatusText
                    |> Expect.equal "There is an in-person quiz for this meeting."
        ]


paperQuizJson : String
paperQuizJson =
    """
    [
      {
        "id": 1,
        "meeting_slug": "week-1",
        "points_possible": 5,
        "is_draft": false,
        "duration": "00:05:00",
        "open_at": "1970-01-01T00:00:01Z",
        "closed_at": "1970-01-01T00:00:02Z",
        "is_open": false,
        "created_at": "1970-01-01T00:00:00Z",
        "updated_at": "1970-01-01T00:00:00Z",
        "is_offline": true
      }
    ]
    """


quizSubmissionJson : String
quizSubmissionJson =
    """
    {
      "quiz_id": 1,
      "user_id": 42,
      "closed_at": "1970-01-01T00:00:02Z",
      "is_open": false,
      "created_at": "1970-01-01T00:00:00Z",
      "updated_at": "1970-01-01T00:00:00Z"
    }
    """


artifactJson : String
artifactJson =
    """
    [
      {
        "id": 1,
        "user_id": 42,
        "quiz_id": 1,
        "slug": "quiz-1-scan",
        "title": "Quiz 1 scan",
        "description": "Scanned quiz",
        "url": "https://example.com/quiz-1.pdf",
        "storage_uri": "s3://course-artifacts/quiz-1.pdf",
        "content_type": "application/pdf",
        "content_length": 123,
        "checksum_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "is_user_visible": true,
        "created_at": "1970-01-01T00:00:00Z",
        "updated_at": "1970-01-01T00:00:00Z"
      },
      {
        "id": 2,
        "user_id": 42,
        "quiz_id": null,
        "slug": "feedback",
        "title": "Feedback",
        "description": "",
        "url": "https://example.com/feedback.pdf",
        "storage_uri": null,
        "content_type": null,
        "content_length": null,
        "checksum_sha256": null,
        "is_user_visible": true,
        "created_at": "1970-01-01T00:00:00Z",
        "updated_at": "1970-01-01T00:00:00Z"
      }
    ]
    """


millis : Int -> Time.Posix
millis =
    Time.millisToPosix
