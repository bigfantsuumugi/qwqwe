open Stdune
open Dune_util

type t

val compare : t -> t -> Ordering.t
val equal : t -> t -> bool
val hash : t -> int

include Comparable_intf.S with type key := t
include Dune_sexp.Conv.S with type t := t
include Stringlike with type t := t

module Opam_compatible : sig
    (** A variant that enforces opam package name constraints: all characters are
        [[a-zA-Z0-9_+-]] with at least a letter. *)

    include Stringlike

    type package_name

    val to_package_name : t -> package_name
  end
  with type package_name := t
