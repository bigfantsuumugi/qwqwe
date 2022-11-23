open Import

module Modules_data : sig
  (** Various information needed about a set of modules.

      This is a subset of [Compilation_context]. We don't use
      [Compilation_context] directory as this would create a circular
      dependency. *)
  type t =
    { dir : Path.Build.t
    ; obj_dir : Path.Build.t Obj_dir.t
    ; sctx : Super_context.t
    ; vimpl : Vimpl.t option
    ; modules : Modules.t
    ; stdlib : Ocaml_stdlib.t option
    ; sandbox : Sandbox_config.t
    }
end

val parse_module_names: unit:Module.t -> modules:Modules.t -> string list -> Module.t list

val parse_deps_exn: file:Path.t -> string list -> string list

val interpret_deps: Modules_data.t -> unit:Module.t -> string list -> Module.t list
