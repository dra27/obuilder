.PHONY: all

all:
	dune build @install @runtest ./stress/stress.exe

ci:
	/usr/bin/opam-2.1 install . --deps-only --depext-only
	/usr/bin/opam-2.1 exec -- dune build @install ./stress/stress.exe
