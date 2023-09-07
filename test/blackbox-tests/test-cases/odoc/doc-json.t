  $ cat > dune-project << EOF
  > (lang dune 3.10)
  > 
  > (package
  >  (name l))
  > EOF

  $ cat > dune << EOF
  > (library
  >  (public_name l))
  > EOF

  $ cat > l.ml << EOF
  > module M = struct
  >   type t = int
  > end
  > EOF

  $ list_docs () {
  >   find _build/default/_doc/_html -name '*.html' -o -name '*.html.json' | sort
  > }

  $ dune build @doc-json
  $ list_docs
  _build/default/_doc/_html/l/L/M/index.html.json
  _build/default/_doc/_html/l/L/index.html.json
  _build/default/_doc/_html/l/index.html.json

@doc will continue generating doc as usual:

  $ dune build @doc
  $ list_docs
  _build/default/_doc/_html/index.html
  _build/default/_doc/_html/l/L/M/index.html
  _build/default/_doc/_html/l/L/M/index.html.json
  _build/default/_doc/_html/l/L/index.html
  _build/default/_doc/_html/l/L/index.html.json
  _build/default/_doc/_html/l/index.html
  _build/default/_doc/_html/l/index.html.json
