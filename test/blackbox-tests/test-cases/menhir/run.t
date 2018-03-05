  $ $JBUILDER build -j1 src/test.exe --display short --root . --debug-dependency-path
      ocamllex src/lexer1.ml
      ocamldep src/lexer1.ml.d
      ocamllex src/lexer2.ml
      ocamldep src/lexer2.ml.d
      ocamldep src/test.ml.d
        menhir src/test_base.{ml,mli}
      ocamldep src/test_base.ml.d
        menhir src/test_menhir1.{ml,mli}
      ocamldep src/test_menhir1.ml.d
      ocamldep src/test_menhir1.mli.d
        ocamlc src/.test.eobjs/test_menhir1.{cmi,cmti}
        ocamlc src/.test.eobjs/lexer1.{cmi,cmo,cmt}
      ocamldep src/test_base.mli.d
        ocamlc src/.test.eobjs/test_base.{cmi,cmti}
        ocamlc src/.test.eobjs/lexer2.{cmi,cmo,cmt}
        ocamlc src/.test.eobjs/test.{cmi,cmo,cmt}
      ocamlopt src/.test.eobjs/test_menhir1.{cmx,o}
      ocamlopt src/.test.eobjs/lexer1.{cmx,o}
      ocamlopt src/.test.eobjs/test_base.{cmx,o}
      ocamlopt src/.test.eobjs/lexer2.{cmx,o}
      ocamlopt src/.test.eobjs/test.{cmx,o}
      ocamlopt src/test.exe
