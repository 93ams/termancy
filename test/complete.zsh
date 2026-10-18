# Runs termancy's zsh completion function outside the completion system:
# `zsh -f complete.zsh <termancy> <word>...` completes the last word of `termancy <word>...` and
# prints what `_termancy` hands to `_describe` (value:description), and `<files ARGS>` for
# `_files`, with `after <IPREFIX>` when the script moved a `--flag=` out of the way.
termancy_exe=$1
shift
# The completion script calls `termancy` by name; route it to the binary under test.
termancy() { "$termancy_exe" "$@" }
# Stand-ins for the completion system, which needs an interactive shell.
compdef() { : }
_describe() { print -rl -- "${(@P)4}" }
_files() { print -r -- "<files${*:+ $*}${IPREFIX:+ after $IPREFIX}>" }
source <(termancy cli completion zsh)
words=(termancy "$@")
CURRENT=${#words}
PREFIX=${words[CURRENT]}
IPREFIX=
_termancy
