# Runs termancy's bash completion the way bash would: `bash complete.bash <termancy> <word>...`
# completes the last word of `termancy <word>...` and prints the candidates, one per line.
termancy_exe=$1
shift
# The completion script calls `termancy` by name; route it to the binary under test.
termancy() { "$termancy_exe" "$@"; }
# `eval`, not `source <(...)`, which bash 3.2 (macOS's) reads as empty.
eval "$(termancy cli completion bash)"
# As some users have it: a candidate the script globbed by mistake would vanish.
shopt -s nullglob
COMP_WORDS=(termancy "$@")
COMP_CWORD=$#
_termancy_complete
[[ $- == *f* ]] && echo "the script left globbing off"
printf '%s\n' "${COMPREPLY[@]}"
