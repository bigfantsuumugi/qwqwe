open Import

(* we need to convince ocamldep that we don't depend on the menhir rules *)
module Menhir = struct end
open Memo.O

let loc_of_dune_file st_dir =
  (match
     let open Option.O in
     let* dune_file = Source_tree.Dir.dune_file st_dir in
     (* TODO not really correct. we need to know the [(subdir ..)] that introduced this *)
     Dune_file0.path dune_file
   with
   | Some s -> s
   | None -> Path.Source.relative (Source_tree.Dir.path st_dir) "_unknown_")
  |> Path.source
  |> Loc.in_file
;;

type t =
  { kind : kind
  ; dir : Path.Build.t
  ; text_files : Filename.Set.t
  ; foreign_sources : Foreign_sources.t Memo.Lazy.t
  ; mlds : (Documentation.t * Path.Build.t list) list Memo.Lazy.t
  ; coq : Coq_sources.t Memo.Lazy.t
  ; ml : Ml_sources.t Memo.Lazy.t
  }

and kind =
  | Standalone
  | Group_root of t list
  | Group_part

let empty kind ~dir =
  { kind
  ; dir
  ; text_files = Filename.Set.empty
  ; ml = Memo.Lazy.of_val Ml_sources.empty
  ; mlds = Memo.Lazy.of_val []
  ; foreign_sources = Memo.Lazy.of_val Foreign_sources.empty
  ; coq = Memo.Lazy.of_val Coq_sources.empty
  }
;;

module Standalone_or_root = struct
  type nonrec standalone_or_root =
    { root : t
    ; subdirs : t Path.Build.Map.t
    ; rules : Rules.t
    }

  type nonrec t = { contents : standalone_or_root Memo.Lazy.t }

  let empty ~dir =
    { contents =
        Memo.Lazy.create (fun () ->
          Memo.return
            { root = empty Standalone ~dir
            ; rules = Rules.empty
            ; subdirs = Path.Build.Map.empty
            })
    }
  ;;

  let root t =
    let+ contents = Memo.Lazy.force t.contents in
    contents.root
  ;;

  let subdirs t =
    let+ contents = Memo.Lazy.force t.contents in
    Path.Build.Map.values contents.subdirs
  ;;

  let rules t =
    let+ contents = Memo.Lazy.force t.contents in
    contents.rules
  ;;
end

type triage =
  | Standalone_or_root of Standalone_or_root.t
  | Group_part of Path.Build.t

let dir t = t.dir
let coq t = Memo.Lazy.force t.coq
let ocaml t = Memo.Lazy.force t.ml
let artifacts t = Memo.Lazy.force t.ml >>= Ml_sources.artifacts

let dirs t =
  match t.kind with
  | Standalone -> [ t ]
  | Group_root subs -> t :: subs
  | Group_part ->
    Code_error.raise
      "Dir_contents.dirs called on a group part"
      [ "dir", Path.Build.to_dyn t.dir ]
;;

let text_files t = t.text_files
let foreign_sources t = Memo.Lazy.force t.foreign_sources

let mlds t ~(stanza : Documentation.t) =
  let+ map = Memo.Lazy.force t.mlds in
  match
    List.find_map map ~f:(fun (stanza', x) ->
      Option.some_if (Loc.equal stanza.loc stanza'.loc) x)
  with
  | Some x -> x
  | None ->
    Code_error.raise
      "Dir_contents.mlds"
      [ "doc", Loc.to_dyn_hum stanza.loc
      ; ( "available"
        , Dyn.(list Loc.to_dyn_hum)
            (List.map map ~f:(fun ((d : Documentation.t), _) -> d.loc)) )
      ]
;;

let build_mlds_map stanzas ~dir ~files =
  let mlds =
    Memo.lazy_ (fun () ->
      Filename.Set.fold files ~init:Filename.Map.empty ~f:(fun fn acc ->
        (* TODO this doesn't handle [.foo.mld] correctly *)
        match String.lsplit2 fn ~on:'.' with
        | Some (s, "mld") -> Filename.Map.set acc s fn
        | _ -> acc)
      |> Memo.return)
  in
  Dune_file.find_stanzas stanzas Documentation.key
  >>= Memo.parallel_map ~f:(fun (doc : Documentation.t) ->
    let+ mlds =
      let+ mlds = Memo.Lazy.force mlds in
      Ordered_set_lang.Unordered_string.eval
        doc.mld_files
        ~standard:mlds
        ~key:Fun.id
        ~parse:(fun ~loc s ->
          match Filename.Map.find mlds s with
          | Some s -> s
          | None ->
            User_error.raise
              ~loc
              [ Pp.textf
                  "%s.mld doesn't exist in %s"
                  s
                  (Path.to_string_maybe_quoted
                     (Path.drop_optional_build_context (Path.build dir)))
              ])
    in
    doc, List.map (Filename.Map.values mlds) ~f:(Path.Build.relative dir))
;;

module rec Load : sig
  val get : Super_context.t -> dir:Path.Build.t -> t Memo.t
  val triage : Super_context.t -> dir:Path.Build.t -> triage Memo.t
end = struct
  let select_deps_files libraries =
    (* Manually add files generated by the (select ...)
       dependencies *)
    List.filter_map libraries ~f:(fun dep ->
      match (dep : Lib_dep.t) with
      | Re_export _ | Direct _ -> None
      | Select s -> Some s.result_fn)
  ;;

  (* As a side-effect, setup user rules and copy_files rules. *)
  let load_text_files sctx st_dir stanzas ~dir ~src_dir =
    let from_source = Source_tree.Dir.filenames st_dir in
    match stanzas with
    | [] -> Memo.return from_source
    | _ :: _ ->
      (* Interpret a few stanzas in order to determine the list of files generated
         by the user. *)
      let+ generated_files =
        let* expander = Super_context.expander sctx ~dir in
        Memo.parallel_map stanzas ~f:(fun stanza ->
          match Stanza.repr stanza with
          | Coq_stanza.Coqpp.T { modules; _ } ->
            Coq_sources.mlg_files ~sctx ~dir ~modules
            >>| List.rev_map ~f:(fun mlg_file ->
              Path.Build.set_extension mlg_file ~ext:".ml" |> Path.Build.basename)
          | Coq_stanza.Extraction.T s ->
            Memo.return (Coq_stanza.Extraction.ml_target_fnames s)
          | Menhir_stanza.T menhir -> Memo.return (Menhir_stanza.targets menhir)
          | Rule_conf.T rule ->
            Simple_rules.user_rule sctx rule ~dir ~expander
            >>| (function
             | None -> []
             | Some targets ->
               (* CR-someday amokhov: Do not ignore directory targets. *)
               Filename.Set.to_list targets.files)
          | Copy_files.T def ->
            Simple_rules.copy_files sctx def ~src_dir ~dir ~expander
            >>| Path.Set.to_list_map ~f:Path.basename
          | Generate_sites_module_stanza.T def ->
            Generate_sites_module_rules.setup_rules sctx ~dir def >>| List.singleton
          | Library.T { buildable; _ }
          | Executables.T { buildable; _ }
          | Tests.T { exes = { buildable; _ }; _ } ->
            let select_deps_files = select_deps_files buildable.libraries in
            let ctypes_files =
              (* Also manually add files generated by ctypes rules. *)
              match buildable.ctypes with
              | None -> []
              | Some ctypes -> Ctypes_field.generated_ml_and_c_files ctypes
            in
            Memo.return (select_deps_files @ ctypes_files)
          | Melange_stanzas.Emit.T { libraries; _ } ->
            Memo.return @@ select_deps_files libraries
          | _ -> Memo.return [])
        >>| List.concat
        >>| Filename.Set.of_list
      in
      Filename.Set.union generated_files from_source
  ;;

  module Key = struct
    module Super_context = Super_context.As_memo_key

    type t = Super_context.t * Path.Build.t

    let to_dyn (sctx, path) =
      Dyn.Tuple [ Super_context.to_dyn sctx; Path.Build.to_dyn path ]
    ;;

    let equal = Tuple.T2.equal Super_context.equal Path.Build.equal
    let hash = Tuple.T2.hash Super_context.hash Path.Build.hash
  end

  let lookup_vlib sctx ~current_dir ~loc ~dir =
    match Path.Build.equal current_dir dir with
    | true ->
      User_error.raise
        ~loc
        [ Pp.text
            "Virtual library and its implementation(s) cannot be defined in the same \
             directory"
        ]
    | false -> Load.get sctx ~dir >>= ocaml
  ;;

  let human_readable_description dir =
    Pp.textf
      "Computing directory contents of %s"
      (Path.to_string_maybe_quoted (Path.build dir))
  ;;

  let make_standalone sctx st_dir ~dir (d : Dune_file.t) =
    let human_readable_description () = human_readable_description dir in
    { Standalone_or_root.contents =
        Memo.lazy_ ~human_readable_description (fun () ->
          let include_subdirs = Loc.none, Include_subdirs.No in
          let ctx = Super_context.context sctx in
          let lib_config =
            let+ ocaml = Context.ocaml ctx in
            ocaml.lib_config
          in
          let stanzas = Dune_file.stanzas d in
          let project = Dune_file.project d in
          let+ files, rules =
            Rules.collect (fun () ->
              let src_dir = Dune_file.dir d in
              stanzas >>= load_text_files sctx st_dir ~src_dir ~dir)
          in
          let dirs = [ { Source_file_dir.dir; path_to_root = []; files } ] in
          let ml =
            Memo.lazy_ (fun () ->
              let lookup_vlib = lookup_vlib sctx ~current_dir:dir in
              let loc = loc_of_dune_file st_dir in
              let libs = Scope.DB.find_by_dir dir >>| Scope.libs in
              let* expander = Super_context.expander sctx ~dir in
              stanzas
              >>= Ml_sources.make
                    ~expander
                    ~dir
                    ~libs
                    ~project
                    ~lib_config
                    ~loc
                    ~include_subdirs
                    ~lookup_vlib
                    ~dirs)
          in
          { Standalone_or_root.root =
              { kind = Standalone
              ; dir
              ; text_files = files
              ; ml
              ; mlds = Memo.lazy_ (fun () -> build_mlds_map d ~dir ~files)
              ; foreign_sources =
                  Memo.lazy_ (fun () ->
                    let dune_version = Dune_project.dune_version project in
                    stanzas >>| Foreign_sources.make ~dune_version ~dirs)
              ; coq =
                  Memo.lazy_ (fun () ->
                    stanzas >>| Coq_sources.of_dir ~dir ~include_subdirs ~dirs)
              }
          ; rules
          ; subdirs = Path.Build.Map.empty
          })
    }
  ;;

  let make_group_root
    sctx
    ~dir
    { Dir_status.Group_root.qualification; dune_file; source_dir; components }
    =
    let include_subdirs =
      let loc, qualif_mode = qualification in
      loc, Include_subdirs.Include qualif_mode
    in
    let loc = loc_of_dune_file source_dir in
    let+ components = components in
    let contents =
      Memo.lazy_
        ~human_readable_description:(fun () -> human_readable_description dir)
        (fun () ->
          let ctx = Super_context.context sctx in
          let stanzas = Dune_file.stanzas dune_file in
          let project = Dune_file.project dune_file in
          let+ (files, subdirs), rules =
            Rules.collect (fun () ->
              Memo.fork_and_join
                (fun () ->
                  stanzas
                  >>= load_text_files
                        sctx
                        source_dir
                        ~src_dir:(Dune_file.dir dune_file)
                        ~dir)
                (fun () ->
                  Memo.parallel_map
                    components
                    ~f:(fun { dir; path_to_group_root; source_dir; stanzas } ->
                      let+ files =
                        load_text_files
                          sctx
                          source_dir
                          stanzas
                          ~src_dir:(Source_tree.Dir.path source_dir)
                          ~dir
                      in
                      { Source_file_dir.dir; path_to_root = path_to_group_root; files })))
          in
          let dirs = { Source_file_dir.dir; path_to_root = []; files } :: subdirs in
          let lib_config =
            let+ ocaml = Context.ocaml ctx in
            ocaml.lib_config
          in
          let ml =
            Memo.lazy_ (fun () ->
              let lookup_vlib = lookup_vlib sctx ~current_dir:dir in
              let libs = Scope.DB.find_by_dir dir >>| Scope.libs in
              let* expander = Super_context.expander sctx ~dir in
              stanzas
              >>= Ml_sources.make
                    ~expander
                    ~dir
                    ~project
                    ~libs
                    ~lib_config
                    ~loc
                    ~lookup_vlib
                    ~include_subdirs
                    ~dirs)
          in
          let foreign_sources =
            Memo.lazy_ (fun () ->
              let dune_version = Dune_project.dune_version project in
              stanzas >>| Foreign_sources.make ~dune_version ~dirs)
          in
          let coq =
            Memo.lazy_ (fun () ->
              stanzas >>| Coq_sources.of_dir ~dir ~dirs ~include_subdirs)
          in
          let subdirs =
            List.map subdirs ~f:(fun { Source_file_dir.dir; path_to_root = _; files } ->
              { kind = Group_part
              ; dir
              ; text_files = files
              ; ml
              ; foreign_sources
              ; mlds = Memo.lazy_ (fun () -> build_mlds_map dune_file ~dir ~files)
              ; coq
              })
          in
          let root =
            { kind = Group_root subdirs
            ; dir
            ; text_files = files
            ; ml
            ; foreign_sources
            ; mlds = Memo.lazy_ (fun () -> build_mlds_map dune_file ~dir ~files)
            ; coq
            }
          in
          { Standalone_or_root.root
          ; rules
          ; subdirs = Path.Build.Map.of_list_map_exn subdirs ~f:(fun x -> x.dir, x)
          })
    in
    { Standalone_or_root.contents }
  ;;

  let get0_impl (sctx, dir) : triage Memo.t =
    Dir_status.DB.get ~dir
    >>= function
    | Is_component_of_a_group_but_not_the_root { group_root; stanzas = _ } ->
      Memo.return @@ Group_part group_root
    | Lock_dir | Generated | Source_only _ ->
      Memo.return @@ Standalone_or_root (Standalone_or_root.empty ~dir)
    | Standalone (st_dir, d) ->
      Memo.return @@ Standalone_or_root (make_standalone sctx st_dir ~dir d)
    | Group_root root ->
      let+ group_root = make_group_root sctx root ~dir in
      Standalone_or_root group_root
  ;;

  let memo0 =
    Memo.create
      "dir-contents-get0"
      get0_impl
      ~input:(module Key)
      ~human_readable_description:(fun (_, dir) ->
        Pp.textf
          "Computing directory contents of %s"
          (Path.to_string_maybe_quoted (Path.build dir)))
  ;;

  let get sctx ~dir =
    Memo.exec memo0 (sctx, dir)
    >>= function
    | Standalone_or_root { contents } ->
      let+ { root; rules = _; subdirs = _ } = Memo.Lazy.force contents in
      root
    | Group_part group_root ->
      Memo.exec memo0 (sctx, group_root)
      >>= (function
       | Group_part _ -> assert false
       | Standalone_or_root { contents } ->
         let+ { root; rules = _; subdirs = _ } = Memo.Lazy.force contents in
         root)
  ;;

  let triage sctx ~dir = Memo.exec memo0 (sctx, dir)
end

include Load

let modules_of_local_lib sctx lib =
  let info = Lib.Local.info lib in
  let dir = Lib_info.src_dir info in
  let* t = get sctx ~dir
  and* libs = Scope.DB.find_by_dir dir >>| Scope.libs in
  ocaml t
  >>= Ml_sources.modules
        ~libs
        ~for_:(Library (Lib_info.lib_id info |> Lib_id.to_local_exn))
;;

let modules_of_lib sctx lib =
  match
    let info = Lib.info lib in
    Lib_info.modules info
  with
  | External modules -> Memo.return modules
  | Local ->
    let+ modules = modules_of_local_lib sctx (Lib.Local.of_lib_exn lib) in
    Some modules
;;

let () =
  Fdecl.set Expander.lookup_artifacts (fun ~dir ->
    Context.DB.by_dir dir
    >>| Context.name
    >>= Super_context.find_exn
    >>= Load.get ~dir
    >>= artifacts)
;;
