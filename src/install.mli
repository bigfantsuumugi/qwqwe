(** Opam install file *)

open Stdune

module Section : sig
  type t =
    | Lib
    | Libexec
    | Bin
    | Sbin
    | Toplevel
    | Share
    | Share_root
    | Etc
    | Doc
    | Stublibs
    | Man
    | Misc

  val t : t Sexp.Of_sexp.t
end

module Entry : sig
  type t = private
    { src     : Path.t
    ; dst     : string option
    ; section : Section.t
    }

  val make : Section.t -> ?dst:string -> Path.t -> t
  val set_src : t -> Path.t -> t

  val relative_installed_path : t -> package:Package.Name.t -> Path.t
  val add_install_prefix : t -> package:Package.Name.t -> prefix:Path.t -> t
end

val files : Entry.t list -> Path.Set.t
val gen_install_file : Entry.t list -> string

val load_install_file : Path.t -> Entry.t list
