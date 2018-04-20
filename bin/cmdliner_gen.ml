open Jbuilder_cmdliner.Cmdliner
open Stdune
open Printf

type arg_info =
  { names        : string list
  ; docv         : string option
  ; doc          : string list
  }

type loc = string * int * int * int
exception Fail of loc * string

let parse_arg_names_and_docv ~loc line =
  let invalid () =
    raise (Fail (loc, "Invalid command line option specification"))
  in
  let rec loop names = function
    | [] -> List.rev names, None
    | [""] -> invalid ()
    | [x] when x.[0] <> '-' -> List.rev names, Some x
    | x :: l ->
      let len = String.length x in
      if len = 0 || x.[0] <> '-' then invalid ();
      let pos = if len > 1 && x.[1] = '-' then 2 else 1 in
      let name = String.sub x ~pos ~len:(len - pos) in
      loop (name :: names) l
  in
  loop [] (String.extract_comma_space_separated_words line)

let parse fn =
  let rec loop ic i acc acc_current_block =
    match input_line ic with
    | exception End_of_file ->
      close_in ic;
      List.rev (acc_current_block :: acc)
    | ""   -> loop ic (i + 1) (acc_current_block :: acc) []
    | line -> loop ic (i + 1) acc ((i, line) :: acc_current_block)
  in
  loop (open_in fn) 1 [] []
  |> List.filter_map ~f:(fun l ->
    match List.rev l with
    | [] -> None
    | (i, line) :: lines ->
      let loc = (fn, i, 0, String.length line) in
      let names, docv = parse_arg_names_and_docv ~loc line in
      Some { names
           ; docv
           ; doc = List.map lines ~f:snd
           })

let ocaml_id_of_string s =
  String.map s ~f:(function
    | '-' -> '_'
    | c   -> c)

let print fn args =
  let module_name =
    Filename.basename fn
    |> Filename.chop_extension
    |> ocaml_id_of_string
    |> String.capitalize_ascii
  in
  printf "module %s(P : Params) = struct\n" module_name;
  List.iteri args ~f:(fun i { names; doc; docv } ->
    if i > 0 then printf "\n";
    let name =
      List.fold_left names ~init:"" ~f:(fun x y ->
        if String.length x > String.length y then
          x
        else
          y)
    in
    let id = ocaml_id_of_string name in
    printf "  let _%s = %S\n" id
      (String.concat ~sep:"/"
         (List.map names ~f:(fun s ->
            if String.length s = 1 then
              "-" ^ s
            else
              "--" ^ s)));
    printf "  let %s =\n" id;
    printf "    Arg.info [%s]\n"
      (String.concat ~sep:"; " (List.map names ~f:(sprintf "%S")));
    printf "      ?docs:P.docs\n";
    Option.iter docv ~f:(
      printf "      ~docv:%S\n");
    printf "      ~doc:{|\n%s|}\n"
      (String.concat doc ~sep:"\n"));
  printf "end\n"

let main =
  let go files =
    let parsed_files =
      List.map files ~f:(fun fn -> (fn, parse fn))
    in
    printf "open Jbuilder_cmdliner.Cmdliner\n";
    printf "\n";
    printf "module type Params = sig\n";
    printf "  val docs : string option\n";
    printf "end\n";
    printf "\n";
    List.iter parsed_files ~f:(fun (fn, args) -> print fn args)
  in
  (Term.(const go
         $ Arg.(non_empty & pos_all file [] & info [] ~docv:"FILE")),
   Term.info "gen-arg-info"
     ~doc:"Generate command line doc for cmdliner from text files.")

let () =
  try
    match Term.eval main ~catch:false with
    | `Error _ -> exit 1
    | _ -> exit 0
  with
  | Fail ((fname, line, start, stop), msg) ->
    eprintf
      "File \"%s\", line %d, characters %d-%d:\n\
       Error: %s\n%!"
      fname line start stop msg;
    exit 1
