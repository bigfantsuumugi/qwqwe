dependencies can be exported transitively:
  $ dune exec ./foo.exe --root transitive
  Entering directory 'transitive'
  Entering directory 'transitive'

transtive deps expressed in the dune-package

  $ dune build @install --root transitive
  Entering directory 'transitive'
  $ cat transitive/_build/install/default/lib/pkg/dune-package
  (lang dune 2.1)
  (name pkg)
  (library
   (name pkg.aaa)
   (kind normal)
   (archives (byte aaa/aaa.cma) (native aaa/aaa.cmxa))
   (plugins (byte aaa/aaa.cma) (native aaa/aaa.cmxs))
   (native_archives aaa/aaa$ext_lib)
   (requires pkg.ccc (re_export pkg.bbb))
   (main_module_name Aaa)
   (modes byte native)
   (modules (singleton (name Aaa) (obj_name aaa) (visibility public) (impl))))
  (library
   (name pkg.bbb)
   (kind normal)
   (archives (byte bbb/bbb.cma) (native bbb/bbb.cmxa))
   (plugins (byte bbb/bbb.cma) (native bbb/bbb.cmxs))
   (native_archives bbb/bbb$ext_lib)
   (requires (re_export pkg.ccc))
   (main_module_name Bbb)
   (modes byte native)
   (modules (singleton (name Bbb) (obj_name bbb) (visibility public) (impl))))
  (library
   (name pkg.ccc)
   (kind normal)
   (archives (byte ccc/ccc.cma) (native ccc/ccc.cmxa))
   (plugins (byte ccc/ccc.cma) (native ccc/ccc.cmxs))
   (native_archives ccc/ccc$ext_lib)
   (main_module_name Ccc)
   (modes byte native)
   (modules (singleton (name Ccc) (obj_name ccc) (visibility public) (impl))))

Re-exporting deps in executables isn't allowed
  $ dune build --root re-export-exe @all
  Entering directory 're-export-exe'
  Info: Creating file dune-project with this contents:
  | (lang dune 2.1)
  File "dune", line 7, characters 13-22:
  7 |  (libraries (re_export foo)))
                   ^^^^^^^^^
  Error: re_export is not allowed here
  [1]
