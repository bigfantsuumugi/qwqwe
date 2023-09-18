In this test we test the translation of a package with a build-env field and no build or
install step into a dune lock file.

  $ . ./helpers.sh
  $ mkrepo

Make a package with a build-env field and no build or install step
  $ mkpkg with-build-env <<'EOF'
  > opam-version: "2.0"
  > build-env: [ [ MY_ENV_VAR = "Hello from env var!" ] ]
  > EOF

  $ mkdir -p $mock_packages/with-build-env/with-build-env.0.0.1/

  $ solve_project <<EOF
  > (lang dune 3.8)
  > (package
  >  (name x)
  >  (allow_empty)
  >  (depends with-build-env))
  > EOF
  Solution for dune.lock:
  with-build-env.0.0.1
  

When there is no build or install step the build environment does not appear in the lock
file.

  $ cat dune.lock/with-build-env.pkg 
  (version 0.0.1)
