# Runs termancy's fish completion the way fish would: `fish complete.fish <termancy> <word>...`
# completes the last word of `termancy <word>...` and prints fish's candidates, one per line,
# as `candidate<TAB>description`.
set -g termancy_exe $argv[1]
# The completion script calls `termancy` by name; route it to the binary under test.
function termancy
    $termancy_exe $argv
end
termancy cli completion fish | source
complete -C (string join -- ' ' termancy $argv[2..-1])
