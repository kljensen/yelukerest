module Pages.Views exposing (aboutView, hasAbout, homeView, pageBody)

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


{-| The `home` body, or nothing. The homepage's fixed links must work whether
or not the row exists or the fetch succeeded, so there is no error state here.
-}
homeView : WebData Pages -> Html msg
homeView pages =
    case findPage "home" pages of
        Just page ->
            pageBody page

        Nothing ->
            Html.text ""


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
                    pageBody page

                Nothing ->
                    notFound

        RemoteData.Failure _ ->
            Html.text "Error loading page!"


findPage : String -> WebData Pages -> Maybe Page
findPage key pages =
    pages
        |> RemoteData.toMaybe
        |> Maybe.andThen (Dict.get key)
