module Pages.Commands exposing (fetchPages, fetchPagesUrl)

import Http
import Msgs exposing (Msg)
import Pages.Model exposing (pagesDecoder)
import RemoteData


fetchPages : Cmd Msg
fetchPages =
    Http.get
        { url = fetchPagesUrl
        , expect = Http.expectJson (RemoteData.fromResult >> Msgs.OnFetchPages) pagesDecoder
        }


fetchPagesUrl : String
fetchPagesUrl =
    "/rest/ui_elements?key=eq.about"
