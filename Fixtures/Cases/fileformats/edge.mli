type ('a, 'b) result = Ok of 'a | Error of 'b
val resolve : string -> (int, string) result
