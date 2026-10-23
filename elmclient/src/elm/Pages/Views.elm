module Pages.Views exposing (aboutView, hasAbout, pageBody)

import Common.Views exposing (markdownToHTML)
import Dict
import Html exposing (Html)
import Html.Attributes as Attrs
import Pages.Model exposing (Page, Pages)
import RemoteData exposing (WebData)


pageBody : Page -> Html msg
pageBody page =
    if page.is_markdown then
        markdownToHTML [] page.body

    else
        Html.div [ Attrs.style "white-space" "pre-wrap" ] [ Html.text page.body ]


{-| The homepage links to About only once the row is known to exist, so a
failed fetch hides the link rather than showing an error.
-}
hasAbout : WebData Pages -> Bool
hasAbout pages =
    findPage "about" pages /= Nothing


aboutView : Html msg -> WebData Pages -> Html msg
aboutView notFound pages =
    case pages of
        RemoteData.NotAsked ->
            Html.text ""

        RemoteData.Loading ->
            Html.text "Loading ..."

        RemoteData.Success found ->
            case Dict.get "about" found of
                Just page ->
                    Html.div [ Attrs.class "about-page" ] [ pageBody page ]

                Nothing ->
                    notFound

        RemoteData.Failure _ ->
            Html.text "Error loading page!"


findPage : String -> WebData Pages -> Maybe Page
findPage key pages =
    pages
        |> RemoteData.toMaybe
        |> Maybe.andThen (Dict.get key)
