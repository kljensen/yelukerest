module Pages.Model exposing (Page, Pages, pagesDecoder)

import Dict exposing (Dict)
import Json.Decode as Decode
import Json.Decode.Pipeline exposing (required)


{-| A faculty-editable block of copy from the `ui_elements` table. The client
reads only the `about` key.
-}
type alias Page =
    { key : String
    , body : String
    , is_markdown : Bool
    }


type alias Pages =
    Dict String Page


pagesDecoder : Decode.Decoder Pages
pagesDecoder =
    Decode.list pageDecoder
        |> Decode.map (List.map (\page -> ( page.key, page )) >> Dict.fromList)


{-| `body` and `is_markdown` are nullable columns; a null reads as an empty
plain-text body.
-}
pageDecoder : Decode.Decoder Page
pageDecoder =
    Decode.succeed Page
        |> required "key" Decode.string
        |> required "body" (Decode.nullable Decode.string |> Decode.map (Maybe.withDefault ""))
        |> required "is_markdown" (Decode.nullable Decode.bool |> Decode.map (Maybe.withDefault False))
