Using same library name in two contexts, where the libraries are defined
in the same dune file

  $ cat > dune-project << EOF
  > (lang dune 3.13)
  > (package (name bar) (allow_empty))
  > (package (name baz) (allow_empty))
  > EOF

  $ cat > dune-workspace << EOF
  > (lang dune 3.13)
  > 
  > (context default)
  > 
  > (context
  >  (default
  >   (name alt-context)))
  > EOF
  $ cat > dune << EOF
  > (library
  >  (name foo)
  >  (enabled_if (= %{context_name} "default")))
  > (library
  >  (name foo)
  >  (enabled_if (= %{context_name} "alt-context")))
  > EOF
  $ cat > foo.ml <<EOF
  > let x = "foo"
  > EOF

  $ dune build --display=short
  Error: Multiple rules generated for _build/alt-context/foo.cmxs:
  - dune:4
  - dune:1
  Error: Multiple rules generated for _build/default/foo.cmxs:
  - dune:4
  - dune:1
  [1]

For public libraries

  $ cat > dune << EOF
  > (library
  >  (name foo)
  >  (public_name bar.foo)
  >  (enabled_if (= %{context_name} "default")))
  > (library
  >  (name foo)
  >  (public_name baz.foo)
  >  (enabled_if (= %{context_name} "alt-context")))
  > EOF

  $ dune build

Mixing public and private libraries

  $ cat > dune << EOF
  > (library
  >  (name foo)
  >  (enabled_if (= %{context_name} "default")))
  > (library
  >  (name foo)
  >  (public_name baz.foo)
  >  (enabled_if (= %{context_name} "alt-context")))
  > EOF

  $ dune build
  Internal error, please report upstream including the contents of _build/log.
  Description:
    ("modules_and_obj_dir: failed lookup",
    { keys = [ "baz.foo" ]; for_ = Library "foo" })
  Raised at Stdune__Code_error.raise in file
    "otherlibs/stdune/src/code_error.ml", line 10, characters 30-62
  Called from Dune_rules__Ml_sources.modules in file
    "src/dune_rules/ml_sources.ml", line 249, characters 22-49
  Called from Fiber__Core.O.(>>|).(fun) in file "vendor/fiber/src/core.ml",
    line 253, characters 36-41
  Called from Fiber__Scheduler.exec in file "vendor/fiber/src/scheduler.ml",
    line 76, characters 8-11
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune/src/exn.ml", line 38, characters 27-56
  Called from Fiber__Scheduler.exec in file "vendor/fiber/src/scheduler.ml",
    line 76, characters 8-11
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune/src/exn.ml", line 38, characters 27-56
  Called from Fiber__Scheduler.exec in file "vendor/fiber/src/scheduler.ml",
    line 76, characters 8-11
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune/src/exn.ml", line 38, characters 27-56
  Called from Fiber__Scheduler.exec in file "vendor/fiber/src/scheduler.ml",
    line 76, characters 8-11
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune/src/exn.ml", line 38, characters 27-56
  Called from Fiber__Scheduler.exec in file "vendor/fiber/src/scheduler.ml",
    line 76, characters 8-11
  Re-raised at Stdune__Exn.raise_with_backtrace in file
    "otherlibs/stdune/src/exn.ml", line 38, characters 27-56
  Called from Fiber__Scheduler.exec in file "vendor/fiber/src/scheduler.ml",
    line 76, characters 8-11
  -> required by ("<unnamed>", ())
  -> required by ("load-dir", In_build_dir "alt-context")
  -> required by
     ("build-alias", { dir = In_build_dir "alt-context"; name = "default" })
  -> required by ("toplevel", ())
  
  I must not crash.  Uncertainty is the mind-killer. Exceptions are the
  little-death that brings total obliteration.  I will fully express my cases. 
  Execution will pass over me and through me.  And when it has gone past, I
  will unwind the stack along its path.  Where the cases are handled there will
  be nothing.  Only I will remain.
  [1]
