module PagesTest exposing (tests)

import Dict
import Expect
import Html.Attributes as Attrs
import Http
import Json.Decode as Decode
import Msgs exposing (Msg)
import Pages.Model exposing (Page, pagesDecoder)
import Pages.Views
import RemoteData
import Test exposing (Test, describe, test)
import Test.Html.Query as Query
import Test.Html.Selector as Selector
import View


tests : Test
tests =
    describe "Pages"
        [ describe "pagesDecoder"
            [ test "keys the rows by key" <|
                \_ ->
                    Decode.decodeString pagesDecoder
                        """[{"key":"home","body":"Welcome","is_markdown":true,"created_at":"2026-01-01T00:00:00+00:00","updated_at":"2026-01-01T00:00:00+00:00"},
                            {"key":"about","body":"About us","is_markdown":false}]"""
                        |> Expect.equal
                            (Ok
                                (Dict.fromList
                                    [ ( "home", Page "home" "Welcome" True )
                                    , ( "about", Page "about" "About us" False )
                                    ]
                                )
                            )
            , test "reads null body and is_markdown as an empty plain-text body" <|
                \_ ->
                    Decode.decodeString pagesDecoder """[{"key":"home","body":null,"is_markdown":null}]"""
                        |> Expect.equal (Ok (Dict.fromList [ ( "home", Page "home" "" False ) ]))
            ]
        , describe "pageBody"
            [ test "renders a plain-text body as text with its line breaks kept" <|
                \_ ->
                    Pages.Views.pageBody (Page "home" "line one\n**not bold**" False)
                        |> Query.fromHtml
                        |> Query.has
                            [ Selector.text "line one\n**not bold**"
                            , Selector.style "white-space" "pre-wrap"
                            ]

            -- The markdown renderer is a JavaScript kernel node that elm-test
            -- cannot see inside, so this checks only that the markdown branch
            -- was taken rather than the plain-text one.
            , test "renders a markdown body with the markdown renderer, not as plain text" <|
                \_ ->
                    Pages.Views.pageBody (Page "home" "**bold**" True)
                        |> Query.fromHtml
                        |> Query.hasNot [ Selector.style "white-space" "pre-wrap" ]
            ]
        , describe "home page"
            [ test "shows the home body and links to About when both rows exist" <|
                \_ ->
                    indexWith (RemoteData.Success (Dict.fromList [ plain "home" "Office hours are on Fridays", plain "about" "x" ]))
                        |> Query.has
                            [ Selector.text "Office hours are on Fridays"
                            , Selector.attribute (Attrs.href "#/about")
                            ]
            , test "keeps the fixed links and hides About when there are no rows" <|
                \_ ->
                    let
                        index =
                            indexWith (RemoteData.Success Dict.empty)
                    in
                    Expect.all
                        [ Query.has [ Selector.attribute (Attrs.href "#/meetings") ]
                        , Query.has [ Selector.attribute (Attrs.href "#/assignments") ]
                        , Query.hasNot [ Selector.attribute (Attrs.href "#/about") ]
                        ]
                        index
            , test "shows no error when the fetch fails" <|
                \_ ->
                    let
                        index =
                            indexWith (RemoteData.Failure Http.NetworkError)
                    in
                    Expect.all
                        [ Query.has [ Selector.attribute (Attrs.href "#/meetings") ]
                        , Query.hasNot [ Selector.containing [ Selector.text "Error" ] ]
                        ]
                        index
            ]
        , describe "about page"
            [ test "shows the about body" <|
                \_ ->
                    aboutWith (RemoteData.Success (Dict.fromList [ plain "about" "Taught by the course staff" ]))
                        |> Query.has [ Selector.text "Taught by the course staff" ]
            , test "is not found when there is no about row" <|
                \_ ->
                    aboutWith (RemoteData.Success (Dict.fromList [ plain "home" "x" ]))
                        |> Query.has [ Selector.text "Not found" ]
            , test "shows a loading state while loading" <|
                \_ ->
                    aboutWith RemoteData.Loading
                        |> Query.has [ Selector.text "Loading" ]
            ]
        ]


plain : String -> String -> ( String, Page )
plain key body =
    ( key, Page key body False )


indexWith : RemoteData.WebData Pages.Model.Pages -> Query.Single Msg
indexWith pages =
    View.indexView RemoteData.NotAsked { courseTitle = "MGT101", mcpEndpoint = "https://www.example.test/mcp" } pages
        |> Query.fromHtml


aboutWith : RemoteData.WebData Pages.Model.Pages -> Query.Single msg
aboutWith pages =
    Pages.Views.aboutView View.notFoundView pages
        |> Query.fromHtml
