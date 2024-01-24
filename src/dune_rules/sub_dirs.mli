open Import

module Status : sig
  type t =
    | Data_only
    | Normal
    | Vendored

  val to_dyn : t -> Dyn.t

  module Or_ignored : sig
    type nonrec t =
      | Ignored
      | Status of t
  end

  module Map : sig
    type status := t

    type 'a t =
      { data_only : 'a
      ; vendored : 'a
      ; normal : 'a
      }

    val merge : 'a t -> 'b t -> f:('a -> 'b -> 'c) -> 'c t
    val find : 'a t -> status -> 'a
    val to_dyn : ('a -> Dyn.t) -> 'a t -> Dyn.t
  end

  module Set : sig
    type t = bool Map.t

    val all : t
    val normal_only : t
  end
end

type subdir_stanzas

val or_default : subdir_stanzas -> Predicate_lang.Glob.t Status.Map.t
val default : Predicate_lang.Glob.t Status.Map.t

type status_map

val eval : Predicate_lang.Glob.t Status.Map.t -> dirs:Filename.t list -> status_map
val status : status_map -> dir:Filename.t -> Status.Or_ignored.t

module Dir_map : sig
  type t

  module Per_dir : sig
    type t =
      { sexps : Dune_lang.Ast.t list
      ; subdir_status : subdir_stanzas
      }

    val to_dyn : t -> Dyn.t
    val equal : t -> t -> bool
  end

  val equal : t -> t -> bool
  val to_dyn : t -> Dyn.t
  val empty : t
  val descend : t -> Filename.t -> t option
  val sub_dirs : t -> Filename.t list
  val merge : t -> t -> t
  val root : t -> Per_dir.t
end

val decode
  :  file:Path.Source.t
  -> Dune_project.t
  -> Dune_lang.Ast.t list
  -> Dir_map.t Memo.t
