Demonstrate an issue with JS file extensions in import statements when using Melange stdlib

  $ cat > dune-project <<EOF
  > (lang dune 3.6)
  > (using melange 0.1)
  > EOF

Set the module system to es6, and javascript extension to .js
  $ cat > dune <<EOF
  > (melange.emit
  >  (alias dist)
  >  (entries hello)
  >  (target dist)
  >  (module_system es6)
  >  (javascript_extension js))
  > EOF

  $ cat > hello.ml <<EOF
  > let foo cb =
  > let foo_id () = cb "hey" in
  > foo_id
  > EOF

  $ dune build @dist

Note the file is correctly named hello.js but the stdlib import uses .mjs extension

  $ cat _build/default/dist/hello.js
  // Generated by Melange
  
  import * as Curry from "melange/lib/es6/curry.mjs";
  
  function foo(cb) {
    return function (param) {
      return Curry._1(cb, "hey");
    };
  }
  
  export {
    foo ,
  }
  /* No side effect */
