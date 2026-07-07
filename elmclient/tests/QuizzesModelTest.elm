module QuizzesModelTest exposing (tests)

import Expect
import Json.Decode as Decode
import Quizzes.Model exposing (paperQuizStatusText, quizSubmissionDecoder, quizzesDecoder)
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


millis : Int -> Time.Posix
millis =
    Time.millisToPosix
