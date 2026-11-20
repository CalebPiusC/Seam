# Runs seam-host.exe (or any packaged executable) with a hard wall-clock limit and returns
# its output. Used by .github/workflows/windows-build.yml.
#
# Why: a regression that makes the host wait forever must fail the build in minutes with the
# output captured so far, not stall until the job's 45-minute timeout with no evidence.
#
# ASCII only on purpose (see the Windows PowerShell 5.1 notes in the workflow).

function Invoke-SeamCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 120,
        [string]$WorkingDirectory = $env:GITHUB_WORKSPACE
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "executable not found: $Path" }

    $stamp = [guid]::NewGuid().ToString('N')
    $out   = Join-Path $env:RUNNER_TEMP "seam-$stamp.out.txt"
    $err   = Join-Path $env:RUNNER_TEMP "seam-$stamp.err.txt"

    $startParams = @{
        FilePath               = $Path
        RedirectStandardOutput = $out
        RedirectStandardError  = $err
        PassThru               = $true
        NoNewWindow            = $true
    }
    if ($ArgumentList.Count -gt 0) { $startParams['ArgumentList'] = $ArgumentList }
    if ($WorkingDirectory)         { $startParams['WorkingDirectory'] = $WorkingDirectory }

    $process  = Start-Process @startParams
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)

    $stdout = if (Test-Path -LiteralPath $out) { [string](Get-Content -LiteralPath $out -Raw) } else { '' }
    $stderr = if (Test-Path -LiteralPath $err) { [string](Get-Content -LiteralPath $err -Raw) } else { '' }

    Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue

    if (-not $finished) {
        try { $process.Kill() } catch { }
        throw ("'{0} {1}' did not finish within {2} s and was killed.`n--- stdout ---`n{3}`n--- stderr ---`n{4}" -f `
                $Path, ($ArgumentList -join ' '), $TimeoutSeconds, $stdout, $stderr)
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}
