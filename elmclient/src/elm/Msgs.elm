module Msgs exposing (..)

import Assignments.Model exposing (Assignment, AssignmentSubmission)
import Auth.Model exposing (CurrentUser)
import Date exposing (Date)
import Http
import Meetings.Model exposing (Meeting)
import Navigation exposing (Location)
import Players.Model exposing (Player, PlayerId)
import Quizzes.Model exposing (Quiz)
import RemoteData exposing (WebData)


type Msg
    = OnFetchPlayers (WebData (List Player))
    | OnFetchMeetings (WebData (List Meeting))
    | OnFetchAssignments (WebData (List Assignment))
    | OnFetchAssignmentSubmissions (WebData (List AssignmentSubmission))
    | OnFetchCurrentUser (WebData CurrentUser)
    | OnFetchQuizzes (WebData (List Quiz))
    | OnLocationChange Location
    | ChangeLevel Player Int
    | OnFetchDate Date
    | OnPlayerSave (Result Http.Error Player)
