(* A small OCaml module with a nested comment: (* still a comment *) *)
let greeting name =
  Printf.sprintf "Hello, %s!" name

let () = print_endline (greeting "Glimt")
