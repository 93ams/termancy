# Runs termancy's PowerShell completion the way PowerShell would:
# `pwsh -NoProfile -File complete.ps1 <termancy> <word>...` completes the last word of
# `termancy <word>...` and prints the candidates, one per line, as `candidate<TAB>description`.
$termancy = $args[0]
$words = @($args | Select-Object -Skip 1)
# The completion script calls `termancy` by name: put the binary under test first on the path.
$env:PATH = (Split-Path -Parent $termancy) + [IO.Path]::PathSeparator + $env:PATH
& $termancy cli completion powershell | Out-String | Invoke-Expression
$line = (@('termancy') + $words) -join ' '
$completion = TabExpansion2 -inputScript $line -cursorColumn $line.Length
# `n, not the platform's line end: Windows PowerShell would end each line with CRLF.
foreach ($match in $completion.CompletionMatches) {
    [Console]::Out.Write("$($match.CompletionText)`t$($match.ToolTip)`n")
}
