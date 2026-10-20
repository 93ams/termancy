# Runs termancy's fish completion the way fish would: `fish complete.fish <termancy> <word>...`
# completes the last word of `termancy <word>...` and prints fish's candidates, one per line,
# as `candidate<TAB>description`.
set -g termancy_exe $argv[1]
set -g asked 0
# The completion script calls `termancy` by name; route it to the binary under test.
function termancy
    contains -- __complete2 $argv; and set -g asked (math $asked + 1)
    $termancy_exe $argv
end
termancy cli completion fish | source
complete -C (string join -- ' ' termancy $argv[2..-1])
# One Tab runs the program once: completers may be slow, or reach the network.
if test $asked -gt 1
    echo "one Tab ran the program $asked times"
end
