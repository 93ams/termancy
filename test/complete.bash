# Runs termancy's bash completion the way bash would: `bash complete.bash <termancy> <word>...`
# completes the last word of `termancy <word>...` and prints the candidates, one per line.
termancy_exe=$1
shift
# The completion script calls `termancy` by name; route it to the binary under test.
termancy() { "$termancy_exe" "$@"; }
# `eval`, not `source <(...)`, which bash 3.2 (macOS's) reads as empty.
eval "$(termancy cli completion bash)"
COMP_WORDS=(termancy "$@")
COMP_CWORD=$#
_termancy_complete
printf '%s\n' "${COMPREPLY[@]}"
