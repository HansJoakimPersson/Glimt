module Glimt exposing (Choice(..), main)

import Html exposing (Html, text)

type Choice value
    = Chosen value
    | Empty

main : Html msg
main =
    let
        answer =
            case Chosen 42 of
                Chosen number ->
                    number

                Empty ->
                    0

        message =
            "Glimt says: \"hello\""

        marker =
            '\n'

        note =
            """multiline
            second line"""

        -- Shown under the title.

        {- outer note
           {- nested note -}
        -}
    in
    text (message ++ String.fromInt answer ++ String.fromChar marker ++ note)
