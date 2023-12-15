Support (explain) field in (menhir) stanza to produce .conflicts file:

  $ cat >parser.mly <<EOF
  > %token START
  > %start <int> start
  > %%
  > start: START | START { 42 }
  > EOF

  $ cat >dune <<EOF
  > (menhir (modules parser) (explain))
  > (library (name lib))
  > EOF

First we check the version guards:

  $ cat >dune-project <<EOF
  > (lang dune 3.12)
  > (using menhir 2.1)
  > EOF

  $ dune build
  File "dune", line 1, characters 25-34:
  1 | (menhir (modules parser) (explain))
                               ^^^^^^^^^
  Error: 'explain' is only available since version 2.2 of the menhir extension.
  Please update your dune-project file to have (using menhir 2.2).
  [1]

  $ cat >dune-project <<EOF
  > (lang dune 3.12)
  > (using menhir 2.2)
  > EOF

  $ dune build
  File "dune-project", line 2, characters 14-17:
  2 | (using menhir 2.2)
                    ^^^
  Error: Version 2.2 of the menhir extension is not supported until version
  3.13 of the dune language.
  Supported versions of this extension in version 3.12 of the dune language:
  - 1.0 to 1.1
  - 2.0 to 2.1
  [1]

  $ cat >dune-project <<EOF
  > (lang dune 3.13)
  > (using menhir 2.2)
  > EOF

  $ dune build
  Warning: one state has reduce/reduce conflicts.
  Warning: one reduce/reduce conflict was arbitrarily resolved.
  File "parser.mly", line 4, characters 15-20:
  Warning: production start -> START is never reduced.
  Warning: in total, 1 production is never reduced.

Let's check that the conflicts file has been generated successfully:

  $ cat _build/default/parser.conflicts
  
  ** Conflict (reduce/reduce) in state 1.
  ** Token involved: #
  ** This state is reached from start after reading:
  
  START
  
  ** The derivations that appear below have the following common factor:
  ** (The question mark symbol (?) represents the spot where the derivations begin to differ.)
  
  start // lookahead token is inherited
  (?)
  
  ** In state 1, looking ahead at #, reducing production
  ** start -> START
  ** is permitted because of the following sub-derivation:
  
  START . 
  
  ** In state 1, looking ahead at #, reducing production
  ** start -> START
  ** is permitted because of the following sub-derivation:
  
  START . 


Let's check that it stops being generated if we remove the (explain) field:

  $ cat >dune <<EOF
  > (menhir (modules parser))
  > (library (name lib))
  > EOF

  $ dune build
  Warning: one state has reduce/reduce conflicts.
  Warning: one reduce/reduce conflict was arbitrarily resolved.
  File "parser.mly", line 4, characters 15-20:
  Warning: production start -> START is never reduced.
  Warning: in total, 1 production is never reduced.

  $ ! test -f _build/default/parser.conflicts