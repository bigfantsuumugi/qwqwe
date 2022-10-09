module Iocp : sig
  type t

  val create : unit -> t

  val run : t -> (unit, exn) result
end

module Event : sig
  type t =
    | Added
    | Removed
    | Modified
    | Renamed_old
    | Renamed_new
end

type t

val create : string -> f:(Event.t -> string -> unit) -> t option
(** return None if the file does not exit *)

val start : t -> Iocp.t -> unit

val stop : t -> unit
