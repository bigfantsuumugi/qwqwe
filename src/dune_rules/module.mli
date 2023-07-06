(** Represents OCaml and Reason source files *)

open Import

module File : sig
  type t

  val dialect : t -> Dialect.t

  val path : t -> Path.t

  val make : Dialect.t -> Path.t -> t
end

module Kind : sig
  type t =
    | Intf_only
    | Virtual
    | Impl
    | Alias of Module_name.Path.t
    | Impl_vmodule
    | Wrapped_compat
    | Root

  include Dune_lang.Conv.S with type t := t
end

module Source : sig
  (** Only the source of a module, not yet associated to a library *)
  type t

  val name : t -> Module_name.t

  val make : ?impl:File.t -> ?intf:File.t -> Module_name.Path.t -> t

  val has : t -> ml_kind:Ml_kind.t -> bool

  val files : t -> File.t list

  val path : t -> Module_name.Path.t

  val to_dyn : t -> Dyn.t

  val src_dir : t -> Path.t
end

type t

val kind : t -> Kind.t

val to_dyn : t -> Dyn.t

(** When you initially construct a [t] using [of_source], it assumes no wrapping
    (so reports an incorrect [obj_name] if wrapping is used) and you might need
    to fix it later with [with_wrapper]. *)
val of_source : visibility:Visibility.t -> kind:Kind.t -> Source.t -> t

val name : t -> Module_name.t

val path : t -> Module_name.Path.t

val source : t -> ml_kind:Ml_kind.t -> File.t option

val pp_flags : t -> (Command.Args.any Command.Args.t * Sandbox_config.t) option

val install_as : t -> Path.Local.t option

val file : t -> ml_kind:Ml_kind.t -> Path.t option

val obj_name : t -> Module_name.Unique.t

val iter : t -> f:(Ml_kind.t -> File.t -> unit Memo.t) -> unit Memo.t

val has : t -> ml_kind:Ml_kind.t -> bool

val set_obj_name : t -> Module_name.Unique.t -> t

val set_path : t -> Module_name.Path.t -> t

val add_file : t -> Ml_kind.t -> File.t -> t

val set_source : t -> Ml_kind.t -> File.t option -> t

val map_files : t -> f:(Ml_kind.t -> File.t -> File.t) -> t

(** Set preprocessing flags *)
val set_pp :
  t -> (Command.Args.any Command.Args.t * Sandbox_config.t) option -> t

val wrapped_compat : t -> t

module Name_map : sig
  type module_ := t

  type t = module_ Module_name.Map.t

  val decode : src_dir:Path.t -> t Dune_lang.Decoder.t

  val encode : t -> src_dir:Path.t -> Dune_lang.t list

  val to_dyn : t -> Dyn.t

  val of_list_exn : module_ list -> t

  val add : t -> module_ -> t
end

module Obj_map : sig
  type module_ := t

  include Map.S with type key = module_

  val find_exn : 'a t -> module_ -> 'a
end

val sources : t -> Path.t list

val visibility : t -> Visibility.t

val encode : t -> src_dir:Path.t -> Dune_lang.t list

val decode : src_dir:Path.t -> t Dune_lang.Decoder.t

(** [pped m] return [m] but with the preprocessed source paths paths *)
val pped : t -> t

(** [ml_source m] returns [m] but with the OCaml syntax source paths *)
val ml_source : t -> t

val version_installed : t -> src_root:Path.t -> install_dir:Path.t -> t

(** Represent a module that is generated by Dune itself. We use a special
    ".ml-gen" extension to indicate this fact and hide it from
    [(glob_files *.ml)].

    XXX should this return the path of the source as well? it will almost always
    be used to create the rule to generate this file *)
val generated :
     ?install_as:Path.Local.t
  -> ?obj_name:Module_name.Unique.t
  -> kind:Kind.t
  -> src_dir:Path.Build.t
  -> Module_name.Path.t
  -> t
