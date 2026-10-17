# Runs snek's bash completion the way bash would: `bash complete.bash <snek> <word>...`
# completes the last word of `snek <word>...` and prints the candidates, one per line.
snek_exe=$1
shift
# The completion script calls `snek` by name; route it to the binary under test.
snek() { "$snek_exe" "$@"; }
source <(snek cli completion bash)
COMP_WORDS=(snek "$@")
COMP_CWORD=$#
_snek_complete
printf '%s\n' "${COMPREPLY[@]}"
