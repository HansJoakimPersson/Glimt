(* Standard ML *)
fun square x = x * x
val total = List.foldl (op +) 0 (List.map square [1, 2, 3])
val () = print ("Hej " ^ Int.toString total ^ "\n")
