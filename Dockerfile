FROM ocaml/opam:ubuntu-20.04
RUN sudo apt-get install -y libsqlite3-dev pkg-config
RUN PATH="$(opam var bin):$PATH" /usr/bin/opam-2.1 switch create --no-switch upgrade ocaml-system
