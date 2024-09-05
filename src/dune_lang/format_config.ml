open Stdune
open Dune_sexp
open Decoder

let syntax =
  Syntax.create
    ~name:"fmt"
    ~desc:"integration with automatic formatters"
    [ (1, 0), `Since (1, 4); (1, 1), `Since (1, 7); (1, 2), `Since (1, 11) ]
;;

module Language = struct
  module T = struct
    type t =
      | Dialect of string
      | Dune
      | Dune_project

    let compare t1 t2 =
      match t1, t2 with
      | Dialect s1, Dialect s2 -> String.compare s1 s2
      | Dialect _, Dune -> Gt
      | Dialect _, Dune_project -> Gt
      | Dune, Dune -> Eq
      | Dune, Dialect _ -> Lt
      | Dune, Dune_project -> Gt
      | Dune_project, Dune_project -> Eq
      | Dune_project, Dialect _ -> Lt
      | Dune_project, Dune -> Lt
    ;;

    let to_dyn =
      let open Dyn in
      function
      | Dialect name -> variant "dialect" [ string name ]
      | Dune -> variant "dune" []
      | Dune_project -> variant "dune-project" []
    ;;
  end

  include Comparable.Make (T)
  include T

  let of_string = function
    | "dune-project" -> Dune_project
    | "dune" -> Dune
    | s -> Dialect s
  ;;

  let in_ext_1_0 = Set.of_list [ Dialect "ocaml"; Dialect "reason" ]
  let in_ext_1_1 = Set.add in_ext_1_0 Dune

  let encode =
    let open Encoder in
    function
    | Dune -> string "dune"
    | Dune_project -> string "dune-project"
    | Dialect d -> string d
  ;;
end

module Enabled_for = struct
  type t =
    | Only of Language.Set.t
    | Dune_2_All
    | All

  let to_dyn =
    let open Dyn in
    function
    | Only l -> variant "only" [ Language.Set.to_dyn l ]
    | Dune_2_All -> string "dune_2_all"
    | All -> string "all"
  ;;

  let includes t =
    match t with
    | Only l -> Language.Set.mem l
    | Dune_2_All ->
      fun l ->
        (match l with
         | Language.Dialect _ | Language.Dune -> true
         | _ -> false)
    | All -> fun _ -> true
  ;;

  let field = field_o "enabled_for" (repeat (map ~f:Language.of_string string))

  let field_ext =
    let+ list_opt = field
    and+ ext_version = Syntax.get_exn syntax in
    match list_opt, ext_version with
    | Some l, _ -> Only (Language.Set.of_list l)
    | None, (1, 0) -> Only Language.in_ext_1_0
    | None, (1, 1) | None, (1, 2) -> Only Language.in_ext_1_1
    | None, _ ->
      Code_error.raise
        "This fmt version does not exist"
        [ "version", Syntax.Version.to_dyn ext_version ]
  ;;

  let equal t1 t2 =
    match t1, t2 with
    | All, All -> true
    | Only l1, Only l2 -> Language.Set.equal l1 l2
    | _ -> false
  ;;
end

type 'enabled_for generic_t =
  { loc : Loc.t
  ; enabled_for : 'enabled_for
  }

type t = Enabled_for.t generic_t

let includes t lang = Enabled_for.includes t.enabled_for lang

let to_dyn { enabled_for; loc = _ } =
  let open Dyn in
  record [ "enabled_for", Enabled_for.to_dyn enabled_for ]
;;

let dparse_args =
  let+ loc = loc
  and+ enabled_for = fields Enabled_for.field_ext in
  { loc; enabled_for }, []
;;

let dune2_record_syntax =
  let+ ef = Enabled_for.field in
  match ef with
  | Some l -> Enabled_for.Only (Language.Set.of_list l)
  | None -> All
;;

let dune2_dec =
  let+ loc = loc
  and+ enabled_for =
    peek
    >>= function
    | None | Some (List _) -> fields dune2_record_syntax
    | Some _ -> keyword "disabled" >>> return (Enabled_for.Only Language.Set.empty)
  in
  { loc; enabled_for }
;;

let enabled_for_all = { loc = Loc.none; enabled_for = Enabled_for.All }
let disabled = { loc = Loc.none; enabled_for = Enabled_for.Only Language.Set.empty }
let enabled_dune_2 = { loc = Loc.none; enabled_for = Enabled_for.Dune_2_All }
let field ~since = field_o "formatting" (Syntax.since Stanza.syntax since >>> dune2_dec)

let is_empty = function
  | { enabled_for = Enabled_for.Only l; _ } -> Language.Set.is_empty l
  | { enabled_for = Enabled_for.Dune_2_All; _ } -> false
  | { enabled_for = All; _ } -> false
;;

let loc t = t.loc

let encode_formatting enabled_for =
  let open Encoder in
  record_fields
    [ field_i
        "enabled_for"
        (List.map ~f:Language.encode)
        (Language.Set.to_list enabled_for)
    ]
;;

let encode_explicit conf =
  let open Encoder in
  [ field_i "formatting" encode_formatting conf ] |> record_fields |> List.hd
;;

let to_explicit { loc; enabled_for } =
  match enabled_for with
  | Enabled_for.All -> None
  | Enabled_for.Dune_2_All -> Some { loc; enabled_for = Language.in_ext_1_1 }
  | Only l -> Some { loc; enabled_for = l }
;;

let encode_opt t = to_explicit t |> Option.map ~f:(fun c -> encode_explicit c.enabled_for)

let of_config ~ext ~dune_lang ~version =
  let dune2 = version >= (2, 0) in
  let dune3_17 = version >= (3, 17) in
  match ext, dune_lang, dune2, dune3_17 with
  | None, None, _, true -> enabled_for_all
  | None, None, true, false -> enabled_dune_2
  | None, None, false, _ -> disabled
  | Some x, None, false, _ | None, Some x, true, true -> x
  | None, Some x, true, false ->
    if x.enabled_for == Enabled_for.All then enabled_dune_2 else x
  | _, Some _, false, _ ->
    Code_error.raise "(formatting ...) stanza requires version 2.0" []
  | Some ext, _, true, _ ->
    let suggestion =
      match to_explicit ext with
      | Some { enabled_for; _ } ->
        let dlang = encode_explicit enabled_for in
        [ Pp.textf "To port it to the new syntax, you can replace this part by:"
        ; Pp.tag User_message.Style.Details (Dune_sexp.pp dlang)
        ]
      | None -> [ Pp.textf "To port it to the new syntax, you can delete this part." ]
    in
    User_error.raise
      ~loc:ext.loc
      (Pp.textf "Starting with (lang dune 2.0), formatting is enabled by default."
       :: suggestion)
;;

let equal { enabled_for; _ } t = Enabled_for.equal enabled_for t.enabled_for
