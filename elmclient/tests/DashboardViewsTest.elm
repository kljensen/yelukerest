module DashboardViewsTest exposing (tests)

import Auth.Model exposing (CurrentUser)
import Dashboard.Views
import Html.Attributes as Attrs
import Models exposing (TimeZone)
import RemoteData
import Set
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import Time exposing (ZoneName(..))
import Users.Model exposing (UserSecret)


tests : Test
tests =
    describe "Dashboard.Views"
        [ test "visible user secrets have a copy button with the secret value" <|
            \_ ->
                Dashboard.Views.dashboard dashboardData
                    |> Query.fromHtml
                    |> Query.find [ Selector.attribute (Attrs.attribute "data-copy-text" baseSecret.body) ]
                    |> Query.has [ Selector.text "copy" ]
        , test "hidden user secrets do not put the secret value on a copy button" <|
            \_ ->
                Dashboard.Views.dashboard { dashboardData | userSecretsToShow = Set.empty }
                    |> Query.fromHtml
                    |> Query.hasNot [ Selector.attribute (Attrs.attribute "data-copy-text" baseSecret.body) ]
        ]


dashboardData :
    { timeZone : TimeZone
    , currentUser : RemoteData.WebData CurrentUser
    , userSecrets : RemoteData.WebData (List UserSecret)
    , userSecretsToShow : Set.Set String
    , meetings : RemoteData.WebData (List a)
    , assignments : RemoteData.WebData (List b)
    , assignmentSubmissions : RemoteData.WebData (List c)
    , assignmentGrades : RemoteData.WebData (List d)
    , assignmentGradeDistributions : RemoteData.WebData (List e)
    , quizzes : RemoteData.WebData (List f)
    , quizSubmissions : RemoteData.WebData (List g)
    , quizArtifacts : RemoteData.WebData (List h)
    , quizGrades : RemoteData.WebData (List i)
    , quizGradeDistributions : RemoteData.WebData (List j)
    }
dashboardData =
    { timeZone = timeZone
    , currentUser = RemoteData.Success currentUser
    , userSecrets = RemoteData.Success [ baseSecret ]
    , userSecretsToShow = Set.fromList [ baseSecret.slug ]
    , meetings = RemoteData.Success []
    , assignments = RemoteData.Success []
    , assignmentSubmissions = RemoteData.Success []
    , assignmentGrades = RemoteData.Success []
    , assignmentGradeDistributions = RemoteData.Success []
    , quizzes = RemoteData.Success []
    , quizSubmissions = RemoteData.Success []
    , quizArtifacts = RemoteData.Success []
    , quizGrades = RemoteData.Success []
    , quizGradeDistributions = RemoteData.Success []
    }


timeZone : TimeZone
timeZone =
    { zone = Time.utc, zoneName = Name "utc" }


currentUser : CurrentUser
currentUser =
    { id = 42
    , netid = "abc123"
    , jwt = "jwt"
    , role = "student"
    , nickname = "student"
    , team_nickname = Just "team-a"
    }


baseSecret : UserSecret
baseSecret =
    { id = 1
    , user_id = Just currentUser.id
    , team_nickname = Nothing
    , slug = "api-key"
    , body = "secret-body"
    }
