module Totals

(* Sums every positive value.
let total values = values |> List.filter (fun v -> v > 0) |> List.sum
