open Import
open Memo.O

(* This file is licensed under The MIT License *)
(* (c) MINES ParisTech 2018-2019               *)
(* (c) INRIA 2020                              *)
(* Written by: Emilio Jesús Gallego Arias *)
(* Written by: Rudi Grinberg *)

open Coq_stanza

let coq_debug = false

let deps_kind = `Coqmod

module Require_map_db = struct
  (* merge all the maps *)
  let impl (requires, buildable_map) =
    Memo.return @@ Coq_require_map.merge_all (buildable_map :: requires)

  let memo =
    let module Input = struct
      type t =
        Coq_module.t Coq_require_map.t list * Coq_module.t Coq_require_map.t

      let equal = ( == )

      let hash = Poly.hash

      let to_dyn = Dyn.opaque
    end in
    Memo.create "coq-require-map-db" ~input:(module Input) impl

  let exec ~requires map = Memo.exec memo (requires, map)
end

(* Coqdep / Coq expect the deps to the directory where the plugin cmxs file are.
   This seems to correspond to src_dir. *)
module Util = struct
  let include_paths ts =
    Path.Set.of_list_map ts ~f:(fun t ->
        let info = Lib.info t in
        Lib_info.src_dir info)

  let coq_nativelib_cmi_dirs ts =
    List.fold_left ts ~init:Path.Set.empty ~f:(fun acc t ->
        let info = Lib.info t in
        (* We want the cmi files *)
        let obj_dir = Obj_dir.public_cmi_dir (Lib_info.obj_dir info) in
        Path.Set.add acc obj_dir)

  let include_flags ts = include_paths ts |> Lib_flags.L.to_iflags

  (* coqdep expects an mlpack file next to the sources otherwise it
   * will omit the cmxs deps *)
  let ml_pack_files lib =
    let plugins =
      let info = Lib.info lib in
      let plugins = Lib_info.plugins info in
      Mode.Dict.get plugins Mode.Native
    in
    let to_mlpack file =
      [ Path.set_extension file ~ext:".mlpack"
      ; Path.set_extension file ~ext:".mllib"
      ]
    in
    List.concat_map plugins ~f:to_mlpack

  let theory_coqc_flag lib =
    let dir = Coq_lib.src_root lib in
    let binding_flag = if Coq_lib.implicit lib then "-R" else "-Q" in
    Command.Args.S
      [ A binding_flag
      ; Path (Path.build dir)
      ; A (Coq_lib.name lib |> Coq_lib_name.wrapper)
      ]
end

let resolve_program sctx ~loc ~dir prog =
  Super_context.resolve_program ~dir sctx prog ~loc:(Some loc)
    ~hint:"opam install coq"

module Bootstrap = struct
  (* the internal boot flag determines if the Coq "standard library" is being
     built, in case we need to explicitly tell Coq where the build artifacts are
     and add `Init.Prelude.vo` as a dependency; there is a further special case
     when compiling the prelude, in this case we also need to tell Coq not to
     try to load the prelude. *)
  type t =
    | No_boot  (** Coq's stdlib is installed globally *)
    | Bootstrap of Coq_lib.t
        (** Coq's stdlib is in scope of the composed build *)
    | Bootstrap_prelude
        (** We are compiling the prelude itself
            [should be replaced with (per_file ...) flags] *)

  let get ~boot_lib ~wrapper_name coq_module =
    match boot_lib with
    | None -> No_boot
    | Some (_loc, lib) -> (
      (* This is here as an optimization, TODO; replace with per_file flags *)
      let init =
        String.equal (Coq_lib_name.wrapper (Coq_lib.name lib)) wrapper_name
        && Option.equal String.equal
             (Option.map ~f:Coq_module.Name.to_string
             @@ List.hd_opt @@ Coq_module.Path.to_list
             @@ Coq_module.prefix coq_module)
             (Some "Init")
      in
      match init with
      | false -> Bootstrap lib
      | true -> Bootstrap_prelude)

  let boot_lib_flags ~coqdoc lib : _ Command.Args.t =
    let dir = Coq_lib.src_root lib in
    S
      (if coqdoc then [ A "--coqlib"; Path (Path.build dir) ]
      else [ A "-boot"; Util.theory_coqc_flag lib ])

  let flags ~coqdoc t : _ Command.Args.t =
    match t with
    | No_boot -> As []
    | Bootstrap lib -> boot_lib_flags ~coqdoc lib
    | Bootstrap_prelude -> As [ "-boot"; "-noinit" ]
end

(* get_libraries from Coq's ML dependencies *)
let libs_of_coq_deps ~lib_db = Resolve.Memo.List.map ~f:(Lib.DB.resolve lib_db)

let select_native_mode ~sctx ~(buildable : Buildable.t) : Coq_mode.t =
  let profile = (Super_context.context sctx).profile in
  if Profile.is_dev profile then VoOnly else snd buildable.mode

let rec resolve_first lib_db = function
  | [] -> assert false
  | [ n ] -> Lib.DB.resolve lib_db (Loc.none, Lib_name.of_string n)
  | n :: l -> (
    let open Memo.O in
    Lib.DB.resolve_when_exists lib_db (Loc.none, Lib_name.of_string n)
    >>= function
    | Some l -> Resolve.Memo.lift l
    | None -> resolve_first lib_db l)

module Context = struct
  type 'a t =
    { deps :
        [ `Coqdep of Action.Prog.t | `Coqmod of Coq_module.t Coq_require_map.t ]
    ; coqc : Action.Prog.t * Path.Build.t
    ; coqdoc : Action.Prog.t
    ; wrapper_name : string
    ; dir : Path.Build.t
    ; expander : Expander.t
    ; buildable : Buildable.t
    ; theories_deps : Coq_lib.t list Resolve.Memo.t
    ; mlpack_rule : unit Action_builder.t
    ; ml_flags : 'a Command.Args.t Resolve.Memo.t
    ; scope : Scope.t
    ; boot_type : Bootstrap.t Resolve.Memo.t
    ; profile_flags : string list Action_builder.t
    ; mode : Coq_mode.t
    ; native_includes : Path.Set.t Resolve.t
    ; native_theory_includes : Path.Build.Set.t Resolve.t
    }

  let coqc ?stdout_to t args =
    let dir = Path.build (snd t.coqc) in
    Command.run ~dir ?stdout_to (fst t.coqc) args

  let coq_flags t =
    let standard = t.profile_flags in
    Expander.expand_and_eval_set t.expander t.buildable.flags ~standard

  let theories_flags t =
    Resolve.Memo.args
      (let open Resolve.Memo.O in
      let+ libs = t.theories_deps in
      Command.Args.S (List.map ~f:Util.theory_coqc_flag libs))

  let coqc_file_flags cctx =
    let file_flags : _ Command.Args.t list =
      [ Dyn (Resolve.Memo.read cctx.ml_flags)
      ; theories_flags cctx
      ; A "-R"
      ; Path (Path.build cctx.dir)
      ; A cctx.wrapper_name
      ]
    in
    ([ Dyn
         (Resolve.Memo.map
            ~f:(fun b -> Bootstrap.flags ~coqdoc:false b)
            cctx.boot_type
         |> Resolve.Memo.read)
     ; S file_flags
     ]
      : _ Command.Args.t list)

  let coqc_native_flags cctx : _ Command.Args.t =
    match cctx.mode with
    | Legacy -> As []
    | VoOnly ->
      As
        [ "-w"
        ; "-deprecated-native-compiler-option"
        ; "-w"
        ; "-native-compiler-disabled"
        ; "-native-compiler"
        ; "ondemand"
        ]
    | Native ->
      let args =
        let open Resolve.O in
        let* native_includes = cctx.native_includes in
        let include_ dir acc = Command.Args.Path dir :: A "-nI" :: acc in
        let native_include_ml_args =
          Path.Set.fold native_includes ~init:[] ~f:include_
        in
        let+ native_theory_includes = cctx.native_theory_includes in
        let native_include_theory_output =
          Path.Build.Set.fold native_theory_includes ~init:[] ~f:(fun dir acc ->
              include_ (Path.build dir) acc)
        in
        (* This dir is relative to the file, by default [.coq-native/] *)
        Command.Args.S
          [ As [ "-w"; "-deprecated-native-compiler-option" ]
          ; As [ "-native-output-dir"; "." ]
          ; As [ "-native-compiler"; "on" ]
          ; S (List.rev native_include_ml_args)
          ; S (List.rev native_include_theory_output)
          ]
      in
      Resolve.args args

  let coqdoc_file_flags cctx =
    let file_flags =
      [ theories_flags cctx
      ; A "-R"
      ; Path (Path.build cctx.dir)
      ; A cctx.wrapper_name
      ]
    in
    [ Command.Args.Dyn
        (Resolve.Memo.map
           ~f:(fun b -> Bootstrap.flags ~coqdoc:true b)
           cctx.boot_type
        |> Resolve.Memo.read)
    ; S file_flags
    ]

  (* compute include flags and mlpack rules *)
  let setup_ml_deps libs theories =
    (* Pair of include flags and paths to mlpack *)
    let libs =
      let open Resolve.Memo.O in
      let* theories = theories in
      let* theories =
        Resolve.Memo.lift
        @@ Resolve.List.concat_map ~f:Coq_lib.libraries theories
      in
      let libs = libs @ theories in
      Lib.closure ~linking:false (List.map ~f:snd libs)
    in
    ( Resolve.Memo.args (Resolve.Memo.map libs ~f:Util.include_flags)
    , let open Action_builder.O in
      let* libs = Resolve.Memo.read libs in
      (* If the mlpack files don't exist, don't fail *)
      Action_builder.paths_existing (List.concat_map ~f:Util.ml_pack_files libs)
    )

  let directories_of_lib ~sctx lib =
    let name = Coq_lib.name lib in
    let dir = Coq_lib.src_root lib in
    let* dir_contents = Dir_contents.get sctx ~dir in
    let+ coq_sources = Dir_contents.coq dir_contents in
    Coq_sources.directories coq_sources ~name

  let setup_native_theory_includes ~sctx ~mode ~theories_deps ~theory_dirs =
    match (mode : Coq_mode.t) with
    | VoOnly | Legacy -> Memo.return (Resolve.return Path.Build.Set.empty)
    | Native ->
      Resolve.Memo.bind theories_deps ~f:(fun theories_deps ->
          let+ l =
            Memo.parallel_map theories_deps ~f:(fun lib ->
                let+ theory_dirs = directories_of_lib ~sctx lib in
                Path.Build.Set.of_list theory_dirs)
          in
          Resolve.return (Path.Build.Set.union_all (theory_dirs :: l)))

  let create ~deps_kind ~coqc_dir sctx ~dir ~wrapper_name ~theories_deps
      ~theory_dirs stanza =
    let buildable =
      match stanza with
      | `Extraction (e : Extraction.t) -> e.buildable
      | `Theory (t : Theory.t) -> t.buildable
    in
    let loc = buildable.loc in
    let rr = resolve_program sctx ~dir ~loc in
    let* expander = Super_context.expander sctx ~dir in
    let* scope = Scope.DB.find_by_dir dir in
    let lib_db = Scope.libs scope in
    (* ML-level flags for depending libraries *)
    let ml_flags, mlpack_rule =
      let res =
        let open Resolve.Memo.O in
        let+ libs =
          Resolve.Memo.List.map buildable.plugins ~f:(fun (loc, name) ->
              let+ lib = Lib.DB.resolve lib_db (loc, name) in
              (loc, lib))
        in
        setup_ml_deps libs theories_deps
      in
      let ml_flags = Resolve.Memo.map res ~f:fst in
      let mlpack_rule =
        let open Action_builder.O in
        let* _, mlpack_rule = Resolve.Memo.read res in
        mlpack_rule
      in
      (ml_flags, mlpack_rule)
    in
    let mode = select_native_mode ~sctx ~buildable in
    let* native_includes =
      let open Resolve.Memo.O in
      resolve_first lib_db [ "coq-core.kernel"; "coq.kernel" ] >>| fun lib ->
      Util.coq_nativelib_cmi_dirs [ lib ]
    in
    let+ native_theory_includes =
      setup_native_theory_includes ~sctx ~mode ~theories_deps ~theory_dirs
    and+ deps =
      match deps_kind with
      | `Coqdep ->
        let+ coqdep = rr "coqdep" in
        `Coqdep coqdep
      | `Coqmod ->
        let* dir_contents = Dir_contents.get sctx ~dir in
        let+ coq_sources = Dir_contents.coq dir_contents in
        let what =
          match stanza with
          | `Extraction e -> `Extraction e
          | `Theory (t : Theory.t) -> `Theory (snd t.name)
        in
        `Coqmod (Coq_sources.require_map coq_sources what)
    and+ coqc = rr "coqc"
    and+ coqdoc = rr "coqdoc"
    and+ profile_flags = Super_context.coq sctx ~dir in
    { deps
    ; coqc = (coqc, coqc_dir)
    ; coqdoc
    ; wrapper_name
    ; dir
    ; expander
    ; buildable
    ; theories_deps
    ; mlpack_rule
    ; ml_flags
    ; scope
    ; boot_type = Resolve.Memo.return Bootstrap.No_boot
    ; profile_flags
    ; mode
    ; native_includes
    ; native_theory_includes
    }

  let for_module t coq_module =
    let boot_type =
      let open Resolve.Memo.O in
      let+ boot_lib = t.scope |> Scope.coq_libs |> Coq_lib.DB.boot_library in
      Bootstrap.get ~boot_lib ~wrapper_name:t.wrapper_name coq_module
    in
    { t with boot_type }
end

let parse_coqdep ~dir ~(boot_type : Bootstrap.t) ~coq_module
    (lines : string list) =
  if coq_debug then Format.eprintf "Parsing coqdep @\n%!";
  let source = Coq_module.source coq_module in
  let invalid phase =
    User_error.raise
      [ Pp.textf "coqdep returned invalid output for %s / [phase: %s]"
          (Path.Build.to_string_maybe_quoted source)
          phase
      ; Pp.verbatim (String.concat ~sep:"\n" lines)
      ]
  in
  let line =
    match lines with
    | [] | _ :: _ :: _ :: _ -> invalid "line"
    | [ line ] -> line
    | [ l1; _l2 ] ->
      (* .vo is produced before .vio, this is fragile tho *)
      l1
  in
  match String.lsplit2 line ~on:':' with
  | None -> invalid "split"
  | Some (basename, deps) -> (
    let ff = List.hd @@ String.extract_blank_separated_words basename in
    let depname, _ = Filename.split_extension ff in
    let modname =
      let name = Coq_module.name coq_module in
      let prefix = Coq_module.prefix coq_module in
      let path = Coq_module.Path.append_name prefix name in
      String.concat ~sep:"/" (Coq_module.Path.to_string_list path)
    in
    if coq_debug then
      Format.eprintf "depname / modname: %s / %s@\n%!" depname modname;
    if depname <> modname then invalid "basename";
    let deps = String.extract_blank_separated_words deps in
    if coq_debug then
      Format.eprintf "deps for %s: %a@\n%!"
        (Path.Build.to_string source)
        (Format.pp_print_list Format.pp_print_string)
        deps;
    (* Add prelude deps for when stdlib is in scope and we are not actually
       compiling the prelude *)
    let deps = List.map ~f:(Path.relative (Path.build dir)) deps in
    match boot_type with
    | No_boot | Bootstrap_prelude -> deps
    | Bootstrap lib ->
      Path.relative (Path.build (Coq_lib.src_root lib)) "Init/Prelude.vo"
      :: deps)

let err_from_not_found ~loc from source =
  User_error.raise ~loc
  @@ (match Coqmod.From.prefix from with
     | Some prefix ->
       [ Pp.textf "could not find module %S with prefix %S"
           (Coqmod.From.require from |> Coqmod.Module.name)
           (prefix |> Coqmod.Module.name)
       ]
     | None ->
       [ Pp.textf "could not find module %S."
           (Coqmod.From.require from |> Coqmod.Module.name)
       ])
  @ [ Pp.textf "%s" @@ Dyn.to_string @@ Coq_require_map.to_dyn source ]

let err_from_ambiguous ~loc _from source =
  User_error.raise ~loc
  @@ [ Pp.textf "TODO ambiguous paths"
     ; Pp.textf "%s" @@ Dyn.to_string @@ Coq_require_map.to_dyn source
     ]

let err_undeclared_plugin ~loc libname =
  User_error.raise ~loc
    Pp.[ textf "TODO undelcared plugin %S" (Lib_name.to_string libname) ]

let coq_require_map_of_theory ~sctx lib =
  let name = Coq_lib.name lib in
  let dir = Coq_lib.src_root lib in
  let* dir_contents = Dir_contents.get sctx ~dir in
  let+ coq_sources = Dir_contents.coq dir_contents in
  Coq_sources.require_map coq_sources (`Theory name)

let deps_of ~sctx ~theories ~plugins ~kind ~dir ~boot_type coq_module =
  match kind with
  | `Coqmod sources ->
    let+ theory_require_maps =
      Memo.parallel_map theories ~f:(fun theory ->
          let+ require_map = coq_require_map_of_theory ~sctx theory in
          (theory, require_map))
      |> Memo.map ~f:Coq_lib.Map.of_list_exn
    in
    Action_builder.dyn_paths
      (let open Action_builder.O in
      let* deps = Coqmod_rules.deps_of coq_module in
      (* convert [Coqmod.t] to a list of paths repping the deps *)
      let+ froms =
        Action_builder.of_memo
        @@
        let f (from_ : Coqmod.From.t) =
          let loc =
            let fname = Coq_module.source coq_module |> Path.Build.to_string in
            Coqmod.From.require from_ |> Coqmod.Module.loc
            |> Coqmod.Loc.to_loc ~fname
          in
          let prefix =
            Option.map (Coqmod.From.prefix from_) ~f:(fun p ->
                Coq_module.Path.of_string @@ Coqmod.Module.name p)
          in
          let suffix =
            Coqmod.From.require from_ |> Coqmod.Module.name
            |> Coq_module.Path.of_string
          in
          let open Memo.O in
          let+ require_map =
            let theories =
              match prefix with
              | Some prefix ->
                List.filter theories ~f:(fun theory ->
                    Coq_module.Path.is_prefix ~prefix
                    @@ Coq_lib.root_path theory)
              | None ->
                (* TODO this is incorrect, needs to include only current theory
                   and boot library if present *)
                theories
            in
            let requires =
              List.map theories ~f:(Coq_lib.Map.find_exn theory_require_maps)
            in
            Require_map_db.exec ~requires sources
          in
          let matches =
            match prefix with
            | Some prefix ->
              Coq_require_map.find_all ~prefix ~suffix require_map
            | None ->
              Coq_require_map.find_all ~prefix:Coq_module.Path.empty ~suffix
                require_map
          in
          match matches with
          | [] -> err_from_not_found ~loc from_ require_map
          | [ m ] -> Path.build (Coq_module.vo_file m)
          | _ -> err_from_ambiguous ~loc from_ require_map
        in
        Coqmod.froms deps |> Memo.parallel_map ~f
      
        and+ boot_deps =
          (* Add prelude deps for when stdlib is in scope and we are not actually
             compiling the prelude *)
          let open Bootstrap in
          let+ boot_type = Resolve.Memo.read boot_type in
          match boot_type with
          | No_boot | Bootstrap_prelude -> []
          | Bootstrap lib ->
            [ Path.relative (Path.build (Coq_lib.src_root lib)) "Init/Prelude.vo"
            ]
        in
      ignore err_undeclared_plugin;
      ignore plugins;
      (* let () =
           let plugins = List.rev_map ~f:snd plugins in
           let libname_of declare =
             (* The name we get back from lexing might be of three forms:
                 1. module_name
                 2. module_name:public_name
                 3. public_name
                We can't do anything with module_name *)
             let token = Coqmod.Ml_module.name declare in
             if String.contains token ':' then
               let token = String.split ~on:':' token in
               Lib_name.of_string_opt @@ List.hd (List.tl token)
             else Lib_name.of_string_opt token
           in
           let undeclared_plugins =
             Coqmod.declares deps
             |> List.filter ~f:(fun declare ->
                    match libname_of declare with
                    | Some name ->
                       List.mem ~equal:Lib_name.equal plugins name
                    | None -> false)
           in
           Printf.printf "undeclared plugins: %s\n"
             (Dyn.list Dyn.string
              @@ List.map ~f:Coqmod.Ml_module.name undeclared_plugins
             |> Dyn.to_string);
           match undeclared_plugins with
           | [] -> ()
           | p :: _ -> (
             let fname = Coq_module.source coq_module |> Path.Build.to_string in
             let loc = Coqmod.Ml_module.loc p |> Coqmod.Loc.to_loc ~fname in
             match libname_of p with
             | Some name -> err_undeclared_plugin ~loc name
             | None -> assert false)
         in *)
      let loads =
        Coqmod.loads deps
        |> List.rev_map ~f:(fun file ->
               let fname = Coqmod.Load.path file in
               Path.build (Path.Build.relative dir fname))
      in
      (* TODO broken *)
      let extradeps =
        Coqmod.extradeps deps
        |> List.rev_map ~f:(fun file ->
               let fname = Coqmod.ExtraDep.file file in
               let path =
                 Coqmod.ExtraDep.from file |> Coqmod.Module.name
                 |> Dune_re.replace_string Re.(compile @@ char '.') ~by:"/"
                 |> Path.Local.of_string |> Path.Build.of_local
               in
               Path.build (Path.Build.relative path fname))
      in

      ((), List.concat [ froms; loads; extradeps; boot_deps ]))
  | `Coqdep _ ->
    let stdout_to = Coq_module.dep_file coq_module in
    Memo.return
    @@ Action_builder.dyn_paths_unit
         (let open Action_builder.O in
         let* boot_type = Resolve.Memo.read boot_type in
         Action_builder.map
           (Action_builder.lines_of (Path.build stdout_to))
           ~f:(parse_coqdep ~dir ~boot_type ~coq_module))

let coqdep_rule (cctx : _ Context.t) ~coqdep ~source_rule ~file_flags coq_module
    =
  (* coqdep needs the full source + plugin's mlpack to be present :( *)
  let source = Coq_module.source coq_module in
  let file_flags =
    [ Command.Args.S file_flags
    ; As [ "-dyndep"; "opt" ]
    ; Dep (Path.build source)
    ]
  in
  let stdout_to = Coq_module.dep_file coq_module in
  (* Coqdep has to be called in the stanza's directory *)
  let open Action_builder.With_targets.O in
  Action_builder.with_no_targets cctx.mlpack_rule
  >>> Action_builder.(with_no_targets (goal source_rule))
  >>> Command.run ~dir:(Path.build cctx.dir) ~stdout_to coqdep file_flags

let coqc_rule (cctx : _ Context.t) ~file_flags coq_module =
  let source = Coq_module.source coq_module in
  let file_flags =
    let wrapper_name, mode = (cctx.wrapper_name, cctx.mode) in
    let objects_to =
      Coq_module.obj_files ~wrapper_name ~mode ~obj_files_mode:Coq_module.Build
        coq_module
      |> List.map ~f:fst
    in
    let native_flags = Context.coqc_native_flags cctx in
    [ Command.Args.Hidden_targets objects_to
    ; native_flags
    ; S file_flags
    ; Dep (Path.build source)
    ]
  in
  let open Action_builder.With_targets.O in
  (* The way we handle the transitive dependencies of .vo files is not safe for
     sandboxing *)
  let sandbox = Sandbox_config.no_sandboxing in
  let coq_flags = Context.coq_flags cctx in
  Context.coqc cctx (Command.Args.dyn coq_flags :: file_flags)
  >>| Action.Full.add_sandbox sandbox

module Coqdoc_mode = struct
  type t =
    | Html
    | Latex

  let flag = function
    | Html -> "--html"
    | Latex -> "--latex"

  let directory t obj_dir (theory : Coq_lib_name.t) =
    Path.Build.relative obj_dir
      (Coq_lib_name.to_string theory
      ^
      match t with
      | Html -> ".html"
      | Latex -> ".tex")

  let alias t ~dir =
    match t with
    | Html -> Alias.doc ~dir
    | Latex -> Alias.make (Alias.Name.of_string "doc-latex") ~dir
end

let coqdoc_directory_targets ~dir:obj_dir (theory : Coq_stanza.Theory.t) =
  let loc = theory.buildable.loc in
  let name = snd theory.name in
  Path.Build.Map.of_list_exn
    [ (Coqdoc_mode.directory Html obj_dir name, loc)
    ; (Coqdoc_mode.directory Latex obj_dir name, loc)
    ]

let coqdoc_rule (cctx : _ Context.t) ~sctx ~name ~file_flags ~mode
    ~theories_deps coq_modules =
  let obj_dir = cctx.dir in
  let doc_dir = Coqdoc_mode.directory mode obj_dir name in
  let file_flags =
    let globs =
      let open Action_builder.O in
      let* theories_deps = Resolve.Memo.read theories_deps in
      Action_builder.of_memo
      @@
      let open Memo.O in
      let+ deps =
        Memo.parallel_map theories_deps ~f:(fun theory ->
            let+ theory_dirs = Context.directories_of_lib ~sctx theory in
            Dep.Set.of_list_map theory_dirs ~f:(fun dir ->
                (* TODO *)
                Glob.of_string_exn Loc.none "*.glob"
                |> File_selector.of_glob ~dir:(Path.build dir)
                |> Dep.file_selector))
      in
      Command.Args.Hidden_deps (Dep.Set.union_all deps)
    in
    [ Command.Args.S file_flags
    ; A "--toc"
    ; A Coqdoc_mode.(flag mode)
    ; A "-d"
    ; Path (Path.build doc_dir)
    ; Deps (List.map ~f:Path.build @@ List.map ~f:Coq_module.source coq_modules)
    ; Dyn globs
    ; Hidden_deps
        (Dep.Set.of_files @@ List.map ~f:Path.build
        @@ List.map ~f:Coq_module.glob_file coq_modules)
    ]
  in
  Command.run ~sandbox:Sandbox_config.needs_sandboxing
    ~dir:(Path.build cctx.dir) cctx.coqdoc file_flags
  |> Action_builder.With_targets.map
       ~f:
         (Action.Full.map ~f:(fun coqdoc ->
              Action.Progn [ Action.mkdir (Path.build doc_dir); coqdoc ]))
  |> Action_builder.With_targets.add_directories ~directory_targets:[ doc_dir ]

let setup_rule cctx ~sctx ~loc ~dir ~source_rule ~ml_targets coq_module =
  if coq_debug then
    Format.eprintf "gen_rule coq_module: %a@\n%!" Pp.to_fmt
      (Dyn.pp (Coq_module.to_dyn coq_module));
  let file_flags = Context.coqc_file_flags cctx in
  let* () =
    match cctx.deps with
    | `Coqmod _ -> Coqmod_rules.add_rule sctx coq_module
    | `Coqdep coqdep ->
      let rule = coqdep_rule cctx ~coqdep ~source_rule ~file_flags coq_module in
      Super_context.add_rule ~loc ~dir sctx rule
  in
  (* Process coqdep and generate rules *)
  let* deps_of =
    let* theories = cctx.theories_deps in
    let* theories = Resolve.read_memo theories in
    let plugins = cctx.buildable.plugins in
    deps_of ~sctx ~theories ~kind:cctx.deps ~dir:cctx.dir
      ~boot_type:cctx.boot_type ~plugins coq_module
  in
  Super_context.add_rule ~loc ~dir sctx
    (let open Action_builder.With_targets.O in
    let coqc =
      Action_builder.with_no_targets deps_of
      >>> coqc_rule cctx ~file_flags coq_module
    in
    Action_builder.With_targets.add coqc ~file_targets:ml_targets)

let coq_modules_of_theory ~sctx lib =
  Action_builder.of_memo
    (let name = Coq_lib.name lib in
     let dir = Coq_lib.src_root lib in
     let* dir_contents = Dir_contents.get sctx ~dir in
     let+ coq_sources = Dir_contents.coq dir_contents in
     Coq_sources.library coq_sources ~name)

let source_rule ~sctx theories =
  (* sources for depending libraries coqdep requires all the files to be in the
     tree to produce correct dependencies, including those of dependencies *)
  Action_builder.dyn_paths_unit
    (let open Action_builder.O in
    let* theories = Resolve.Memo.read theories in
    let+ l =
      Action_builder.List.map theories ~f:(coq_modules_of_theory ~sctx)
    in
    List.concat l |> List.rev_map ~f:(fun m -> Path.build (Coq_module.source m)))

let setup_cctx_and_modules ~sctx ~dir ~dir_contents (s : Theory.t) theory =
  let name = snd s.name in
  let wrapper_name = Coq_lib_name.wrapper name in
  let theories_deps =
    Resolve.Memo.bind theory ~f:(fun theory ->
        Resolve.Memo.lift @@ Coq_lib.theories_closure theory)
  in
  let* coq_dir_contents = Dir_contents.coq dir_contents in
  let theory_dirs =
    Coq_sources.directories coq_dir_contents ~name |> Path.Build.Set.of_list
  in
  let coqc_dir = (Super_context.context sctx).build_dir in
  let+ cctx =
    Context.create sctx ~deps_kind ~coqc_dir ~dir ~wrapper_name ~theories_deps
      ~theory_dirs (`Theory s)
  in
  let coq_modules = Coq_sources.library coq_dir_contents ~name in
  (cctx, coq_modules)

let setup_vo_rules ~sctx ~dir ~(cctx : _ Context.t) (s : Theory.t) theory
    coq_modules =
  let loc = s.buildable.loc in
  let source_rule =
    let theories =
      let open Resolve.Memo.O in
      let* theory = theory in
      let+ theories = cctx.theories_deps in
      theory :: theories
    in
    source_rule ~sctx theories
  in
  Memo.parallel_iter coq_modules ~f:(fun m ->
      let cctx = Context.for_module cctx m in
      setup_rule cctx ~sctx ~loc ~dir ~source_rule ~ml_targets:[] m)

let setup_coqdoc_rules ~sctx ~dir ~cctx (s : Theory.t) coq_modules =
  let loc, name = (s.buildable.loc, snd s.name) in
  let rule =
    let file_flags = Context.coqdoc_file_flags cctx in
    fun mode ->
      let* () =
        coqdoc_rule cctx ~sctx ~mode ~theories_deps:cctx.theories_deps ~name
          ~file_flags coq_modules
        |> Super_context.add_rule ~loc ~dir sctx
      in
      Coqdoc_mode.directory mode cctx.dir name
      |> Path.build |> Action_builder.path
      |> Rules.Produce.Alias.add_deps (Coqdoc_mode.alias mode ~dir) ~loc
  in
  let* () = rule Html in
  rule Latex

let setup_rules ~sctx ~dir ~dir_contents (s : Theory.t) =
  let theory =
    let* scope = Scope.DB.find_by_dir dir in
    let coq_lib_db = Scope.coq_libs scope in
    Coq_lib.DB.resolve coq_lib_db ~coq_lang_version:s.buildable.coq_lang_version
      s.name
  in
  let* cctx, coq_module_sources =
    setup_cctx_and_modules ~sctx ~dir ~dir_contents s theory
  in
  let* () = setup_vo_rules ~sctx ~dir ~cctx s theory coq_module_sources in
  let+ () = setup_coqdoc_rules ~sctx ~dir ~cctx s coq_module_sources in
  ()

let coqtop_args_theory ~sctx ~dir ~dir_contents (s : Theory.t) coq_module_source
    =
  let name = s.name in
  let* scope = Scope.DB.find_by_dir dir in
  let coq_lib_db = Scope.coq_libs scope in
  let theory =
    Coq_lib.DB.resolve coq_lib_db name
      ~coq_lang_version:s.buildable.coq_lang_version
  in
  let name = snd s.name in
  let* coq_dir_contents = Dir_contents.coq dir_contents in
  let* cctx =
    let wrapper_name = Coq_lib_name.wrapper name in
    let theories_deps =
      Resolve.Memo.bind theory ~f:(fun theory ->
          Resolve.Memo.lift @@ Coq_lib.theories_closure theory)
    in
    let theory_dirs = Coq_sources.directories coq_dir_contents ~name in
    let theory_dirs = Path.Build.Set.of_list theory_dirs in
    let coqc_dir = (Super_context.context sctx).build_dir in
    Context.create sctx ~deps_kind ~coqc_dir ~dir ~wrapper_name ~theories_deps
      ~theory_dirs (`Theory s)
  in
  let cctx = Context.for_module cctx coq_module_source in
  let+ boot_type = Resolve.Memo.read_memo cctx.boot_type in
  (Context.coqc_file_flags cctx, boot_type)

(******************************************************************************)
(* Install rules *)
(******************************************************************************)

(* This is here for compatibility with Coq < 8.11, which expects plugin files to
   be in the folder containing the `.vo` files *)
let coq_plugins_install_rules ~scope ~package ~dst_dir (s : Theory.t) =
  let lib_db = Scope.libs scope in
  let+ ml_libs =
    Resolve.Memo.read_memo (libs_of_coq_deps ~lib_db s.buildable.plugins)
  in
  let rules_for_lib lib =
    let info = Lib.info lib in
    (* Don't install libraries that don't belong to this package *)
    if
      let name = Package.name package in
      Option.equal Package.Name.equal (Lib_info.package info) (Some name)
    then
      let loc = Lib_info.loc info in
      let plugins = Lib_info.plugins info in
      Mode.Dict.get plugins Mode.Native
      |> List.map ~f:(fun plugin_file ->
             (* Safe because all coq libraries are local for now *)
             let plugin_file = Path.as_in_build_dir_exn plugin_file in
             let plugin_file_basename = Path.Build.basename plugin_file in
             let dst =
               Path.Local.(to_string (relative dst_dir plugin_file_basename))
             in
             let entry = Install.Entry.make Section.Lib_root ~dst plugin_file in
             (* TODO this [loc] should come from [s.buildable.libraries] *)
             Install.Entry.Sourced.create ~loc entry)
    else []
  in
  List.concat_map ~f:rules_for_lib ml_libs

let install_rules ~sctx ~dir s =
  match s with
  | { Theory.package = None; _ } -> Memo.return []
  | { Theory.package = Some package; buildable; _ } ->
    let mode = select_native_mode ~sctx ~buildable in
    let loc = s.buildable.loc in
    let* scope = Scope.DB.find_by_dir dir in
    let* dir_contents = Dir_contents.get sctx ~dir in
    let name = snd s.name in
    (* This must match the wrapper prefix for now to remain compatible *)
    let dst_suffix = Coq_lib_name.dir name in
    (* These are the rules for now, coq lang 2.0 will make this uniform *)
    let dst_dir =
      if s.boot then
        (* We drop the "Coq" prefix (!) *)
        Path.Local.of_string "coq/theories"
      else
        let coq_root = Path.Local.of_string "coq/user-contrib" in
        Path.Local.relative coq_root dst_suffix
    in
    (* Also, stdlib plugins are handled in a hardcoded way, so no compat install
       is needed *)
    let* coq_plugins_install_rules =
      if s.boot then Memo.return []
      else coq_plugins_install_rules ~scope ~package ~dst_dir s
    in
    let wrapper_name = Coq_lib_name.wrapper name in
    let to_path f = Path.reach ~from:(Path.build dir) (Path.build f) in
    let to_dst f = Path.Local.to_string @@ Path.Local.relative dst_dir f in
    let make_entry (orig_file : Path.Build.t) (dst_file : string) =
      let entry =
        Install.Entry.make Section.Lib_root ~dst:(to_dst dst_file) orig_file
      in
      Install.Entry.Sourced.create ~loc entry
    in
    let+ coq_sources = Dir_contents.coq dir_contents in
    coq_sources |> Coq_sources.library ~name
    |> List.concat_map ~f:(fun (vfile : Coq_module.t) ->
           let obj_files =
             Coq_module.obj_files ~wrapper_name ~mode
               ~obj_files_mode:Coq_module.Install vfile
             |> List.map
                  ~f:(fun ((vo_file : Path.Build.t), (install_vo_file : string))
                     -> make_entry vo_file install_vo_file)
           in
           let vfile = Coq_module.source vfile in
           let vfile_dst = to_path vfile in
           make_entry vfile vfile_dst :: obj_files)
    |> List.rev_append coq_plugins_install_rules

let setup_coqpp_rules ~sctx ~dir (s : Coqpp.t) =
  let* coqpp = resolve_program sctx ~dir ~loc:s.loc "coqpp" in
  let mlg_rule m =
    let source = Path.build (Path.Build.relative dir (m ^ ".mlg")) in
    let target = Path.Build.relative dir (m ^ ".ml") in
    let args = [ Command.Args.Dep source; Hidden_targets [ target ] ] in
    let build_dir = (Super_context.context sctx).build_dir in
    Command.run ~dir:(Path.build build_dir) coqpp args
  in
  List.rev_map ~f:mlg_rule s.modules
  |> Super_context.add_rules ~loc:s.loc ~dir sctx

let setup_extraction_rules ~sctx ~dir ~dir_contents (s : Extraction.t) =
  let* cctx =
    let wrapper_name = "DuneExtraction" in
    let* theories_deps =
      let* scope = Scope.DB.find_by_dir dir in
      let coq_lib_db = Scope.coq_libs scope in
      Coq_lib.DB.requires_for_user_written coq_lib_db s.buildable.theories
        ~coq_lang_version:s.buildable.coq_lang_version
    in
    let theory_dirs = Path.Build.Set.empty in
    let theories_deps = Resolve.Memo.lift theories_deps in
    Context.create sctx ~deps_kind ~coqc_dir:dir ~dir ~wrapper_name
      ~theories_deps ~theory_dirs (`Extraction s)
  in
  let* coq_module =
    let+ coq = Dir_contents.coq dir_contents in
    Coq_sources.extract coq s
  in
  let ml_targets =
    Extraction.ml_target_fnames s |> List.map ~f:(Path.Build.relative dir)
  in
  let source_rule =
    let theories = source_rule ~sctx cctx.theories_deps in
    let open Action_builder.O in
    theories >>> Action_builder.path (Path.build (Coq_module.source coq_module))
  in
  setup_rule cctx ~sctx ~loc:s.buildable.loc ~dir ~source_rule coq_module
    ~ml_targets

let coqtop_args_extraction ~sctx ~dir ~dir_contents (s : Extraction.t) =
  let* cctx =
    let wrapper_name = "DuneExtraction" in
    let* theories_deps =
      let* scope = Scope.DB.find_by_dir dir in
      let coq_lib_db = Scope.coq_libs scope in
      Coq_lib.DB.requires_for_user_written coq_lib_db s.buildable.theories
        ~coq_lang_version:s.buildable.coq_lang_version
    in
    let theory_dirs = Path.Build.Set.empty in
    let theories_deps = Resolve.Memo.lift theories_deps in
    Context.create sctx ~deps_kind ~coqc_dir:dir ~dir ~wrapper_name
      ~theories_deps ~theory_dirs (`Extraction s)
  in
  let* coq_module =
    let+ coq = Dir_contents.coq dir_contents in
    Coq_sources.extract coq s
  in
  let cctx = Context.for_module cctx coq_module in
  let+ boot_type = Resolve.Memo.read_memo cctx.boot_type in
  (Context.coqc_file_flags cctx, boot_type)

let deps_of ~dir ~boot_type mod_ =
  (* TODO fix *)
  let kind = failwith "TODO dune coq top unsupported" in
  let sctx = failwith "" in
  Action_builder.of_memo_join
  @@ deps_of ~sctx ~theories:[] ~plugins:[] ~kind ~dir ~boot_type mod_
