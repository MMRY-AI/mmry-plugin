# codex-hook-group.ps1 - start every UserPromptSubmit hook of an installed plugin at once, the way Codex
# 0.169.0 does on Windows, and report how long each took (#33967 round 4).
#
# Codex starts each hook as its own `powershell.exe -NoProfile -Command <commandWindows>`, all nine of a
# message together, writes the payload to each one's stdin, and stops a hook at its `timeout`. This does
# the same with a native process start (no Git Bash fork in between, as from Codex), and writes one line
# per hook: <label>|<ms from start to exit>|<limit s>|<exit code>|<stdout file>. It never stops a hook:
# a hook still running at its limit is reported with its real time, which is what the test judges.
param(
    [Parameter(Mandatory=$true)][string]$Root,      # the installed plugin root, Windows form
    [Parameter(Mandatory=$true)][string]$Payload,   # the payload file
    [Parameter(Mandatory=$true)][string]$OutDir     # where each hook's stdout is written
)
$ErrorActionPreference = 'Stop'
$d = Get-Content -Raw (Join-Path $Root 'hooks\codex-hooks.json') | ConvertFrom-Json
$hooks = @()
foreach ($g in $d.hooks.UserPromptSubmit) { foreach ($h in $g.hooks) { $hooks += $h } }
$pay = [IO.File]::ReadAllText($Payload)
$runs = @()
$n = 0
foreach ($h in $hooks) {
    $n++
    $c = $h.commandWindows.Replace('${PLUGIN_ROOT}', $Root)
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.ArgumentList.Add('-NoProfile'); $psi.ArgumentList.Add('-Command'); $psi.ArgumentList.Add($c)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $t0 = [DateTime]::Now
    $p = [Diagnostics.Process]::Start($psi)
    $runs += [pscustomobject]@{
        Label = ($c -replace '^.*codex-hook\.cmd" ', ''); Limit = [int]$h.timeout; P = $p; T0 = $t0; N = $n
        Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync()
    }
}
foreach ($r in $runs) { $r.P.StandardInput.Write($pay); $r.P.StandardInput.Close() }
foreach ($r in $runs) {
    [void]$r.P.WaitForExit(120000)
    $ms = [int]($r.P.ExitTime - $r.T0).TotalMilliseconds
    $f = Join-Path $OutDir ("hook{0}.out" -f $r.N)
    [IO.File]::WriteAllText($f, $r.Out.Result)
    "{0}|{1}|{2}|{3}|{4}" -f $r.Label, $ms, $r.Limit, $r.P.ExitCode, $f
}
