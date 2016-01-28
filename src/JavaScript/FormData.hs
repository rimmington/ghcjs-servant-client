{-# LANGUAGE JavaScriptFFI #-}

module JavaScript.FormData (
    FormData (..), FormDataProp (..), newFormData, appendFormData
    ) where

import Data.JSString (pack)
import GHCJS.Types (JSVal, JSString)

newtype FormData = FormData { unFormData :: JSVal }

data FormDataProp = FormDataString String String
                  | FormDataBlob String JSVal String

foreign import javascript unsafe "new global.FormData()"
    newFormData :: IO FormData

appendFormData :: FormData -> FormDataProp -> IO ()
appendFormData fd (FormDataString n v)  = js_append2 fd (pack n) (pack v)
appendFormData fd (FormDataBlob n v fn) = js_append3 fd (pack n) v (pack fn)

foreign import javascript unsafe "$1.append($2, $3)"
    js_append2 :: FormData -> JSString -> JSString -> IO ()

foreign import javascript unsafe "$1.append($2, $3, $4)"
    js_append3 :: FormData -> JSString -> JSVal -> JSString -> IO ()
