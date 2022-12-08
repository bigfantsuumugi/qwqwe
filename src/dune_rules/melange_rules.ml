open Import
module CC = Compilation_context

let ocaml_flags sctx ~dir melange =
  let open Memo.O in
  let open Super_context in
  let* expander = expander sctx ~dir in
  let* flags =
    let+ ocaml_flags = env_node sctx ~dir >>= Env_node.ocaml_flags in
    Ocaml_flags.make_with_melange ~melange ~default:ocaml_flags
      ~eval:(Expander.expand_and_eval_set expander)
  in
  build_dir_is_vendored dir >>| function
  | true ->
    let ocaml_version = (context sctx).version in
    with_vendored_flags ~ocaml_version flags
  | false -> flags

let lib_output_dir ~target_dir ~lib_dir =
  Path.Build.append_source target_dir
    (Path.Build.drop_build_context_exn lib_dir)

let make_js_name ~js_ext ~dst_dir m =
  let name = Melange.js_basename m ^ js_ext in
  Path.Build.relative dst_dir name

let virtual_dst_dir_and_modules sctx ~target_dir ~implements =
  let open Memo.O in
  match implements with
  | None -> Memo.return None
  | Some vlib ->
    let* vlib = vlib in
    let* vlib = Resolve.read_memo vlib in
    let name = Lib.name vlib in
    let vlib = Lib.Local.of_lib_exn vlib in
    let info = Lib.Local.info vlib in
    let* dir_contents =
      let dir = Lib_info.src_dir info in
      Dir_contents.get sctx ~dir
    in
    let* modules =
      Dir_contents.ocaml dir_contents
      >>| Ml_sources.modules ~for_:(Library name)
    in
    let lib_dir = Lib_info.src_dir info in
    let dst_dir = lib_output_dir ~target_dir ~lib_dir in
    Memo.return (Some (dst_dir, modules))

let local_of_lib ~loc lib =
  match Lib.Local.of_lib lib with
  | Some s -> s
  | None ->
    let lib_name = Lib.name lib in
    User_error.raise ~loc
      [ Pp.textf "The external library %s cannot be used"
          (Lib_name.to_string lib_name)
      ]

let js_includes ~loc ~sctx ~target_dir ~requires_link ~scope ~js_ext =
  let open Resolve.Memo.O in
  Command.Args.memo
    (Resolve.Memo.args
       (let* (libs : Lib.t list) = requires_link in
        let project = Scope.project scope in
        let deps_of_lib (lib : Lib.t) =
          let lib_name = Lib.name lib in
          let info =
            let lib = local_of_lib ~loc lib in
            Lib.Local.info lib
          in
          match Lib_info.virtual_ info with
          | Some _ ->
            (* Js rules for virtual libs are added by their implementations *)
            Resolve.Memo.return ([] |> Dep.Set.of_list)
          | None ->
            let lib_dir = Lib_info.src_dir info in
            let dst_dir = lib_output_dir ~target_dir ~lib_dir in
            let open Memo.O in
            let modules_group =
              Dir_contents.get sctx ~dir:lib_dir
              >>= Dir_contents.ocaml
              >>| Ml_sources.modules ~for_:(Library lib_name)
            in
            let* source_modules = modules_group >>| Modules.impl_only in
            let of_module ~dst_dir m =
              let output = make_js_name ~js_ext ~dst_dir m in
              Dep.file (Path.build output)
            in
            let virtual_modules =
              let implements = Lib.implements lib in
              virtual_dst_dir_and_modules sctx ~target_dir ~implements
            in
            let* virtual_modules = virtual_modules in
            let virtual_deps =
              match virtual_modules with
              | None -> []
              | Some (dst_dir, virtual_modules) ->
                let source_modules = Modules.impl_only virtual_modules in
                List.map source_modules ~f:(of_module ~dst_dir)
            in
            let impl_deps = List.map source_modules ~f:(of_module ~dst_dir) in
            Resolve.Memo.return
              (List.rev_append virtual_deps impl_deps |> Dep.Set.of_list)
        in
        let* hidden_libs = Resolve.Memo.List.map libs ~f:deps_of_lib in
        let hidden_deps = Dep.Set.union_all hidden_libs in
        Resolve.Memo.return
          (Command.Args.S
             [ Lib_flags.L.include_flags ~project libs Melange
             ; Hidden_deps hidden_deps
             ])))

let build_js ~loc ~dir ~pkg_name ~mode ~module_system ~dst_dir ~obj_dir ~sctx
    ~lib_deps_js_includes ~js_ext m =
  let cm_kind = Lib_mode.Cm_kind.Melange Cmj in
  let open Memo.O in
  let* compiler = Melange_binary.melc sctx ~loc:(Some loc) ~dir in
  let src = Obj_dir.Module.cm_file_exn obj_dir m ~kind:cm_kind in
  let output = make_js_name ~js_ext ~dst_dir m in
  let obj_dir =
    [ Command.Args.A "-I"; Path (Path.build (Obj_dir.melange_dir obj_dir)) ]
  in
  let melange_package_args =
    let pkg_name_args =
      match pkg_name with
      | None -> []
      | Some pkg_name ->
        [ "--bs-package-name"; Package.Name.to_string pkg_name ]
    in

    let js_modules_str = Melange.Module_system.to_string module_system in
    "--bs-module-type" :: js_modules_str :: pkg_name_args
  in
  let lib_deps_js_includes = Command.Args.as_any lib_deps_js_includes in
  Super_context.add_rule sctx ~dir ~loc ~mode
    (Command.run
       ~dir:(Path.build (Super_context.context sctx).build_dir)
       compiler
       [ Command.Args.S obj_dir
       ; lib_deps_js_includes
       ; As melange_package_args
       ; A "-o"
       ; Target output
       ; Dep (Path.build src)
       ])

let add_rules_for_entries ~sctx ~dir ~expander ~dir_contents ~scope
    ~compile_info ~target_dir ~mode (mel : Melange_stanzas.Emit.t) =
  let open Memo.O in
  (* Use "mobjs" rather than "objs" to avoid a potential conflict with a library
     of the same name *)
  let* modules, obj_dir =
    Dir_contents.ocaml dir_contents
    >>| Ml_sources.modules_and_obj_dir ~for_:(Melange { target = mel.target })
  in
  let* () = Check_rules.add_obj_dir sctx ~obj_dir in
  let* flags = ocaml_flags sctx ~dir mel.compile_flags in
  let requires_link = Lib.Compile.requires_link compile_info in
  let direct_requires = Lib.Compile.direct_requires compile_info in
  let* modules, pp =
    Buildable_rules.modules_rules sctx
      (Melange
         { preprocess = mel.preprocess
         ; preprocessor_deps = mel.preprocessor_deps
         ; (* TODO still needed *)
           lint = Preprocess.Per_module.default ()
         ; (* why is this always false? *)
           empty_module_interface_if_absent = false
         })
      expander ~dir scope modules
  in
  let* cctx =
    let js_of_ocaml = None in
    Compilation_context.create () ~loc:mel.loc ~super_context:sctx ~expander
      ~scope ~obj_dir ~modules ~flags ~requires_link
      ~requires_compile:direct_requires ~preprocessing:pp ~js_of_ocaml
      ~opaque:Inherit_from_settings ~package:mel.package
      ~modes:
        { ocaml = { byte = None; native = None }
        ; melange = Some (Requested Loc.none)
        }
  in
  let pkg_name = Option.map mel.package ~f:Package.name in
  let loc = mel.loc in
  let js_ext = mel.javascript_extension in
  let requires_link = Memo.Lazy.force requires_link in
  let lib_deps_js_includes =
    js_includes ~loc ~sctx ~target_dir ~requires_link ~scope ~js_ext
  in
  let* () = Module_compilation.build_all cctx in
  let module_list =
    Modules.fold_no_vlib modules ~init:[] ~f:(fun x acc -> x :: acc)
  in
  let dst_dir =
    Path.Build.append_source target_dir (Path.Build.drop_build_context_exn dir)
  in
  let* () =
    Memo.parallel_iter module_list ~f:(fun m ->
        (* Should we check module kind? *)
        build_js ~dir ~loc ~pkg_name ~mode ~module_system:mel.module_system
          ~dst_dir ~obj_dir ~sctx ~lib_deps_js_includes ~js_ext m)
  in
  let* () =
    match mel.alias with
    | None -> Memo.return ()
    | Some alias_name ->
      let alias = Alias.make alias_name ~dir in
      let deps =
        List.rev_map module_list ~f:(fun m ->
            make_js_name ~js_ext ~dst_dir m |> Path.build)
        |> Action_builder.paths
      in
      Rules.Produce.Alias.add_deps alias deps
  in
  let* requires_compile = Compilation_context.requires_compile cctx in
  let preprocess =
    Preprocess.Per_module.with_instrumentation mel.preprocess
      ~instrumentation_backend:
        (Lib.DB.instrumentation_backend (Scope.libs scope))
  in
  let stdlib_dir = (Super_context.context sctx).stdlib_dir in
  Memo.return
    ( cctx
    , Merlin.make ~requires:requires_compile ~stdlib_dir ~flags ~modules
        ~source_dirs:Path.Source.Set.empty ~libname:None ~preprocess ~obj_dir
        ~ident:(Lib.Compile.merlin_ident compile_info)
        ~dialects:(Dune_project.dialects (Scope.project scope))
        ~modes:`Melange_emit )

let add_rules_for_libraries ~dir ~scope ~target_dir ~sctx ~requires_link ~mode
    (mel : Melange_stanzas.Emit.t) =
  Memo.parallel_iter requires_link ~f:(fun lib ->
      let open Memo.O in
      let lib_name = Lib.name lib in
      let* lib, lib_compile_info =
        Lib.DB.get_compile_info (Scope.libs scope) lib_name
      in
      let info =
        let lib = local_of_lib ~loc:mel.loc lib in
        Lib.Local.info lib
      in
      let loc = Lib_info.loc info in
      let lib_dir = Lib_info.src_dir info in
      let obj_dir = Lib_info.obj_dir info in
      let dst_dir = lib_output_dir ~target_dir ~lib_dir in
      let modules_group =
        Dir_contents.get sctx ~dir:lib_dir
        >>= Dir_contents.ocaml
        >>| Ml_sources.modules ~for_:(Library lib_name)
      in
      let requires_link =
        Memo.Lazy.force (Lib.Compile.requires_link lib_compile_info)
      in
      let js_ext = mel.javascript_extension in
      let pkg_name = Lib_info.package info in
      let lib_deps_js_includes =
        js_includes ~loc:mel.loc ~sctx ~target_dir ~requires_link ~scope ~js_ext
      in
      let* () =
        let* virtual_modules =
          let implements = Lib.implements lib in
          virtual_dst_dir_and_modules sctx ~target_dir ~implements
        in
        match virtual_modules with
        | None -> Memo.return ()
        | Some (dst_dir, virtual_modules) ->
          let source_modules = Modules.impl_only virtual_modules in
          Memo.parallel_iter source_modules ~f:(fun m ->
              build_js ~loc ~dir ~pkg_name ~mode
                ~module_system:mel.module_system ~dst_dir ~obj_dir ~sctx
                ~lib_deps_js_includes ~js_ext m)
      in
      let* source_modules = modules_group >>| Modules.impl_only in
      Memo.parallel_iter source_modules
        ~f:
          (build_js ~loc ~dir ~pkg_name ~mode ~module_system:mel.module_system
             ~dst_dir ~obj_dir ~sctx ~lib_deps_js_includes ~js_ext))

let compile_info ~scope (mel : Melange_stanzas.Emit.t) =
  let open Memo.O in
  let dune_version = Scope.project scope |> Dune_project.dune_version in
  let+ pps =
    Resolve.Memo.read_memo
      (Preprocess.Per_module.with_instrumentation mel.preprocess
         ~instrumentation_backend:
           (Lib.DB.instrumentation_backend (Scope.libs scope)))
    >>| Preprocess.Per_module.pps
  in
  let merlin_ident = Merlin_ident.for_melange ~target:mel.target in
  Lib.DB.resolve_user_written_deps (Scope.libs scope) (`Melange_emit mel.target)
    mel.libraries ~pps ~dune_version ~merlin_ident

let emit_rules ~dir_contents ~dir ~scope ~sctx ~expander mel =
  let open Memo.O in
  let* compile_info = compile_info ~scope mel in
  let target_dir = Path.Build.relative dir mel.target in
  let mode =
    match mel.promote with
    | None -> Rule.Mode.Standard
    | Some p -> Promote p
  in
  let f () =
    let+ cctx_and_merlin =
      add_rules_for_entries ~sctx ~dir ~expander ~dir_contents ~scope
        ~compile_info ~target_dir ~mode mel
    and+ () =
      let* requires_link =
        Memo.Lazy.force (Lib.Compile.requires_link compile_info)
      in
      let* requires_link = Resolve.read_memo requires_link in
      add_rules_for_libraries ~dir ~scope ~target_dir ~sctx ~requires_link ~mode
        mel
    in
    cctx_and_merlin
  in
  Buildable_rules.with_lib_deps
    (Super_context.context sctx)
    compile_info ~dir ~f
