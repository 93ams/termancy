# Runs snek's fish completion the way fish would: `fish complete.fish <snek> <word>...`
# completes the last word of `snek <word>...` and prints fish's candidates, one per line,
# as `candidate<TAB>description`.
set -g snek_exe $argv[1]
# The completion script calls `snek` by name; route it to the binary under test.
function snek
    $snek_exe $argv
end
snek cli completion fish | source
complete -C (string join -- ' ' snek $argv[2..-1])
