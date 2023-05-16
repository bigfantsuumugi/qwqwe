(** Dune representation of the source tree *)

open Import

module Dune_file : sig
  val fname : Filename.t

  val alternative_fname : Filename.t

  type kind = private
    | Plain
    | Ocaml_script

  type t

  val to_dyn : t -> Dyn.t

  val get_static_sexp : t -> Dune_lang.Ast.t list

  val kind : t -> kind

  val path : t -> Path.Source.t option
end

module Dir : sig
  type t

  type error = Missing_run_t of Cram_test.t

  val cram_tests : t -> (Cram_test.t, error) result list Memo.t

  val path : t -> Path.Source.t

  val files : t -> Filename.Set.t

  val file_paths : t -> Path.Source.Set.t

  type sub_dir

  val sub_dirs : t -> sub_dir Filename.Map.t

  val sub_dir_as_t : sub_dir -> t Memo.t

  module Make_map_reduce (M : Memo.S) (Outcome : Monoid) : sig
    (** Traverse sub-directories recursively, pass them to [f] and combine
        intermediate results into a single one via [M.combine]. *)
    val map_reduce :
         t
      -> traverse:Sub_dirs.Status.Set.t
      -> f:(t -> Outcome.t M.t)
      -> Outcome.t M.t
  end

  val sub_dir_names : t -> Filename.Set.t

  val status : t -> Sub_dirs.Status.t

  (** Return the contents of the dune (or jbuild) file in this directory *)
  val dune_file : t -> Dune_file.t option

  (** Return the project this directory is part of *)
  val project : t -> Dune_project.t

  val to_dyn : t -> Dyn.t
end

val root : unit -> Dir.t Memo.t

module Make_map_reduce_with_progress (M : Memo.S) (Outcome : Monoid) : sig
  (** Traverse starting from the root and report progress in the status line *)
  val map_reduce :
       traverse:Sub_dirs.Status.Set.t
    -> f:(Dir.t -> Outcome.t M.t)
    -> Outcome.t M.t
end

val find_dir : Path.Source.t -> Dir.t option Memo.t

(** [nearest_dir t fn] returns the directory with the longest path that is an
    ancestor of [fn]. *)
val nearest_dir : Path.Source.t -> Dir.t Memo.t

(** [nearest_vcs t fn] returns the version control system with the longest root
    path that is an ancestor of [fn]. *)
val nearest_vcs : Path.Source.t -> Vcs.t option Memo.t

val files_of : Path.Source.t -> Path.Source.Set.t Memo.t

(** [true] iff the path is a vendored directory *)
val is_vendored : Path.Source.t -> bool Memo.t
