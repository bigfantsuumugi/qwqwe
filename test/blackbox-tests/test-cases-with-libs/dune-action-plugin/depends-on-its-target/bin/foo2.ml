open Dune_action_plugin

let path = Path.of_string "bar2"

let action =
  let open Dune_action_plugin.O in
  write_file ~path ~data:"Hello from bar2!"
  |> stage ~f:(fun () ->
         let+ data = read_file ~path in
         print_endline data)

let () = run action
