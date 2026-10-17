# Runs snek's zsh completion function outside the completion system:
# `zsh -f complete.zsh <snek> <word>...` completes the last word of `snek <word>...` and
# prints what `_snek` hands to `_describe` (value:description), and `<files ARGS>` for
# `_files`, with `after <IPREFIX>` when the script moved a `--flag=` out of the way.
snek_exe=$1
shift
# The completion script calls `snek` by name; route it to the binary under test.
snek() { "$snek_exe" "$@" }
# Stand-ins for the completion system, which needs an interactive shell.
compdef() { : }
_describe() { print -rl -- "${(@P)4}" }
_files() { print -r -- "<files${*:+ $*}${IPREFIX:+ after $IPREFIX}>" }
source <(snek cli completion zsh)
words=(snek "$@")
CURRENT=${#words}
PREFIX=${words[CURRENT]}
IPREFIX=
_snek
