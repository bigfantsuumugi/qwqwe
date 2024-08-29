open Import

let man =
  [ `S "DESCRIPTION"
  ; `P {|Commands for doing package management with dune|}
  ; `Blocks Common.help_secs
  ]
;;

let subcommands =
  [ Lock.command; Print_solver_env.command; Outdated.command; Validate_lock_dir.command ]
;;

let info name =
  let doc = "Experimental package management" in
  Cmd.info name ~doc ~man
;;

let group = Cmd.group (info "pkg") subcommands

module Alias = struct
  let group = Cmd.group (info "package") subcommands
end
