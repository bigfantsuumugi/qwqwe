  $ dune build --display short --debug-dependency-path @all
        coqdep theories/a.v.d
        ocamlc src_b/.ml_plugin_b.objs/byte/ml_plugin_b.{cmi,cmo,cmt}
      ocamldep src_b/.ml_plugin_b.objs/ml_plugin_b__Simple_b.impl.d
        ocamlc src_a/.ml_plugin_a.objs/byte/ml_plugin_a.{cmi,cmo,cmt}
      ocamldep src_a/.ml_plugin_a.objs/ml_plugin_a__Gram.intf.d
      ocamldep src_a/.ml_plugin_a.objs/ml_plugin_a__Simple.impl.d
         coqpp src_a/gram.ml
      ocamlopt src_b/.ml_plugin_b.objs/native/ml_plugin_b.{cmx,o}
      ocamlopt src_a/.ml_plugin_a.objs/native/ml_plugin_a.{cmx,o}
        ocamlc src_a/.ml_plugin_a.objs/byte/ml_plugin_a__Gram.{cmi,cmti}
        ocamlc src_a/.ml_plugin_a.objs/byte/ml_plugin_a__Simple.{cmi,cmo,cmt}
      ocamldep src_a/.ml_plugin_a.objs/ml_plugin_a__Gram.impl.d
        ocamlc src_b/.ml_plugin_b.objs/byte/ml_plugin_b__Simple_b.{cmi,cmo,cmt}
      ocamlopt src_a/.ml_plugin_a.objs/native/ml_plugin_a__Simple.{cmx,o}
      ocamlopt src_a/.ml_plugin_a.objs/native/ml_plugin_a__Gram.{cmx,o}
        ocamlc src_a/.ml_plugin_a.objs/byte/ml_plugin_a__Gram.{cmo,cmt}
      ocamlopt src_b/.ml_plugin_b.objs/native/ml_plugin_b__Simple_b.{cmx,o}
        ocamlc src_b/ml_plugin_b.cma
      ocamlopt src_a/ml_plugin_a.{a,cmxa}
        ocamlc src_a/ml_plugin_a.cma
      ocamlopt src_b/ml_plugin_b.{a,cmxa}
      ocamlopt src_a/ml_plugin_a.cmxs
      ocamlopt src_b/ml_plugin_b.cmxs
          coqc theories/a.{glob,vo}
