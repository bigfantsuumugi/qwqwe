(** Jobs display for TUI *)

include Jobs_display_intf.S with type state = Rpc_running_jobs.State.t
