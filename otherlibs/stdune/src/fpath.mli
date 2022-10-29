(** Functions on paths that are represented as strings *)

type mkdir_result =
  | Created (** The directory was created. *)
  | Already_exists (** The directory already exists. No action was taken. *)
  | Already_exists_not_directory
      (** The file already exists, but it was not a directory. *)
  | Parent_not_directory (** The parent exists but is not a directory. *)
  | Missing_parent_directory
      (** No parent directory, use [mkdir_p] if you want to create it too. *)

val dyn_of_mkdir_result : mkdir_result -> Dyn.t
val mkdir : ?perms:int -> string -> mkdir_result

type mkdir_p_result =
  | Created (** The directory was created. *)
  | Already_exists (** The directory already exists. No action was taken. *)
  | Already_exists_not_directory of string
      (** A file with the same name as the [string] already exists but is not a
          directory. *)

val dyn_of_mkdir_p_result : mkdir_p_result -> Dyn.t
val mkdir_p : ?perms:int -> string -> mkdir_p_result

type follow_symlink_error =
  | Not_a_symlink
  | Max_depth_exceeded
  | Unix_error of Dune_filesystem_stubs.Unix_error.Detailed.t

val follow_symlink : string -> (string, follow_symlink_error) result

(** [follow_symlinks path] returns a file path that is equivalent to [path], but
    free of symbolic links. The value [None] is returned if the maximum symbolic
    link depth is reached (i.e., [follow_symlink] returns the value
    [Error Max_depth_exceeded] on some intermediate path). *)
val follow_symlinks : string -> string option

val unlink : string -> unit
val unlink_no_err : string -> unit
val initial_cwd : string

type clear_dir_result =
  | Cleared
  | Directory_does_not_exist

val clear_dir : string -> clear_dir_result

(** If the path does not exist, this function is a no-op. *)
val rm_rf : string -> unit

val is_root : string -> bool
