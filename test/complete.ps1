# Runs snek's PowerShell completion the way PowerShell would:
# `pwsh -NoProfile -File complete.ps1 <snek> <word>...` completes the last word of
# `snek <word>...` and prints the candidates, one per line, as `candidate<TAB>description`.
$snek = $args[0]
$words = @($args | Select-Object -Skip 1)
# The completion script calls `snek` by name: put the binary under test first on the path.
$env:PATH = (Split-Path -Parent $snek) + [IO.Path]::PathSeparator + $env:PATH
& $snek cli completion powershell | Out-String | Invoke-Expression
$line = (@('snek') + $words) -join ' '
$completion = TabExpansion2 -inputScript $line -cursorColumn $line.Length
# `n, not the platform's line end: Windows PowerShell would end each line with CRLF.
foreach ($match in $completion.CompletionMatches) {
    [Console]::Out.Write("$($match.CompletionText)`t$($match.ToolTip)`n")
}
