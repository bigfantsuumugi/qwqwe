module Style = struct
  type t =
    | Loc
    | Error
    | Warning
    | Kwd
    | Id
    | Prompt
    | Details
    | Ok
    | Debug
    | Success
    | Ansi_styles of Ansi_color.Style.t list
end

module Annot = struct
  type t = ..

  let format = ref (fun _ -> assert false)

  let pp t = !format t

  module type S = sig
    type payload

    val make : payload -> t

    val check : t -> (payload -> 'a) -> (unit -> 'a) -> 'a
  end

  module Make (M : sig
    type payload

    val to_dyn : payload -> Dyn.t
  end) : S with type payload = M.payload = struct
    type payload = M.payload

    type t += A of M.payload

    let make t = A t

    let check t on_match on_failure =
      match t with
      | A t -> on_match t
      | _ -> on_failure ()

    let () =
      let f = function
        | A t -> Dyn.pp (M.to_dyn t)
        | other -> !format other
      in
      format := f
  end

  module Has_embedded_location = Make (struct
    type payload = unit

    let to_dyn = Unit.to_dyn
  end)

  module Needs_stack_trace = Make (struct
    type payload = unit

    let to_dyn = Unit.to_dyn
  end)
end

module Print_config = struct
  type t = Style.t -> Ansi_color.Style.t list

  open Ansi_color.Style

  let default : Style.t -> _ = function
    | Loc -> [ bold ]
    | Error -> [ bold; fg_red ]
    | Warning -> [ bold; fg_magenta ]
    | Kwd -> [ bold; fg_blue ]
    | Id -> [ bold; fg_yellow ]
    | Prompt -> [ bold; fg_green ]
    | Details -> [ dim; fg_white ]
    | Ok -> [ dim; fg_green ]
    | Debug -> [ underlined; fg_bright_cyan ]
    | Success -> [ bold; fg_green ]
    | Ansi_styles l -> l
end

type t =
  { loc : Loc0.t option
  ; paragraphs : Style.t Pp.t list
  ; hints : Style.t Pp.t list
  ; annots : Annot.t list
  }

let make ?loc ?prefix ?(hints = []) ?(annots = []) paragraphs =
  let paragraphs =
    match (prefix, paragraphs) with
    | None, l -> l
    | Some p, [] -> [ p ]
    | Some p, x :: l -> Pp.concat ~sep:Pp.space [ p; x ] :: l
  in
  { loc; hints; paragraphs; annots }

let pp { loc; paragraphs; hints; annots = _ } =
  let open Pp.O in
  let paragraphs =
    match hints with
    | [] -> paragraphs
    | _ ->
      List.append paragraphs
        (List.map hints ~f:(fun hint -> Pp.verbatim "Hint:" ++ Pp.space ++ hint))
  in
  let paragraphs = List.map paragraphs ~f:Pp.box in
  let paragraphs =
    match loc with
    | None -> paragraphs
    | Some { Loc0.start; stop } ->
      let start_c = start.pos_cnum - start.pos_bol in
      let stop_c = stop.pos_cnum - start.pos_bol in
      Pp.tag Style.Loc
        (Pp.textf "File %S, line %d, characters %d-%d:" start.pos_fname
           start.pos_lnum start_c stop_c)
      :: paragraphs
  in
  Pp.vbox (Pp.concat_map paragraphs ~sep:Pp.nop ~f:(fun pp -> Pp.seq pp Pp.cut))

let print ?(config = Print_config.default) t =
  Ansi_color.print (Pp.map_tags (pp t) ~f:config)

let prerr ?(config = Print_config.default) t =
  Ansi_color.prerr (Pp.map_tags (pp t) ~f:config)

(* As found here http://rosettacode.org/wiki/Levenshtein_distance#OCaml *)
let levenshtein_distance s t =
  let m = String.length s
  and n = String.length t in
  (* for all i and j, d.(i).(j) will hold the Levenshtein distance between the
     first i characters of s and the first j characters of t *)
  let d = Array.make_matrix ~dimx:(m + 1) ~dimy:(n + 1) 0 in
  for i = 0 to m do
    (* the distance of any first string to an empty second string *)
    d.(i).(0) <- i
  done;
  for j = 0 to n do
    (* the distance of any second string to an empty first string *)
    d.(0).(j) <- j
  done;
  for j = 1 to n do
    for i = 1 to m do
      if s.[i - 1] = t.[j - 1] then
        d.(i).(j) <- d.(i - 1).(j - 1)
      (* no operation required *)
      else
        d.(i).(j) <-
          min
            (d.(i - 1).(j) + 1) (* a deletion *)
            (min
               (d.(i).(j - 1) + 1) (* an insertion *)
               (d.(i - 1).(j - 1) + 1) (* a substitution *))
    done
  done;
  d.(m).(n)

let did_you_mean s ~candidates =
  let candidates =
    List.filter candidates ~f:(fun candidate ->
        levenshtein_distance s candidate < 3)
  in
  match candidates with
  | [] -> []
  | l -> [ Pp.textf "did you mean %s?" (String.enumerate_or l) ]

let to_string t =
  Format.asprintf "%a" Pp.to_fmt (pp { t with loc = None })
  |> String.drop_prefix ~prefix:"Error: "
  |> Option.value_exn |> String.trim

let is_loc_none loc =
  match loc with
  | None -> true
  | Some loc -> loc = Loc0.none

let has_embedded_location msg =
  List.exists msg.annots ~f:(fun annot ->
      Annot.Has_embedded_location.check annot (fun () -> true) (fun () -> false))

let has_location msg = (not (is_loc_none msg.loc)) || has_embedded_location msg

let needs_stack_trace msg =
  List.exists msg.annots ~f:(fun annot ->
      Annot.Needs_stack_trace.check annot (fun () -> true) (fun () -> false))
