#Requires -Version 7
<#
.SYNOPSIS
    Drive a chunked/batched adversarial review: run the deterministic spine
    (run-review.ps1) once per chunk under one shared run id, at a fixed chunk
    concurrency, so every chunk leaves a metrics.json for aggregation.

.DESCRIPTION
    A large diff cannot be reviewed as one panel run (it overruns the
    cross-vendor reviewers and dilutes findings — see the skill, §0a). The fix is
    to tile the surface into cohesive chunks and run the full three-phase pipeline
    once per chunk, then synthesise (§5). This script standardises that fan-out
    that was previously hand-rolled per audit:

      - one shared RunRoot (<temp>/adversarial-review/<stamp>) and RunId for all
        chunks, so aggregate-and-emit.ps1 groups them as ONE dashboard run;
      - each chunk gets its own subdirectory <RunRoot>/<chunkId> and runs the
        spine with the chunk's pathspec;
      - chunks run -BatchSize at a time (each spine itself runs the manifest's
        enabled reviewers in parallel — currently four, so wall concurrency
        ≈ BatchSize × reviewer count);
      - it STOPS at the judge boundary, exactly like the spine. Adjudication,
        per-chunk reports, §5 synthesis, and the aggregate-verdict.json that feeds
        accepted/judge into aggregate-and-emit.ps1 remain host judgment.

.PARAMETER ChunkManifest
    Path to a JSON array of chunks:
      [ { "id": "L1", "label": "Library: Orders",
          "pathspec": ["src/Orders", ":!**/*.Designer.cs"] }, ... ]
    `id` must be a filesystem-safe slug (becomes the chunk subdir). `pathspec` is
    forwarded to the spine after `--`.

.PARAMETER RepoPath
    Repository root. Defaults to the git toplevel of the current directory.

.PARAMETER RunRoot
    Shared run working directory. Defaults to <temp>/adversarial-review/<UTC stamp>.

.PARAMETER Target
    Spine target for every chunk (default 'audit' — empty tree vs HEAD, the usual
    whole-surface audit). Any spine target is accepted.

.PARAMETER ContextPath
    Repo context file(s) forwarded to every chunk's reviewers (read-only
    background). Keep tight.

.PARAMETER BatchSize
    Chunks run concurrently (default 3).

.OUTPUTS
    Writes <RunRoot>/<chunkId>/* per chunk (including metrics.json), a
    <RunRoot>/batch-summary.json roll-up, and prints the RunRoot + next steps.

.EXAMPLE
    pwsh -NoProfile -File batch-review.ps1 -ChunkManifest chunks.json -Target audit
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ChunkManifest,
    [string] $RepoPath,
    [string] $RunRoot,
    [string] $Target = 'audit',
    [string[]] $ContextPath,

    [ValidateRange(1, [int]::MaxValue)]
    [int] $BatchSize = 3
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$spine = Join-Path $scriptDir 'run-review.ps1'
if (-not (Test-Path -LiteralPath $spine)) { Write-Error "run-review.ps1 not found beside this script."; exit 2 }

if (-not (Test-Path -LiteralPath $ChunkManifest)) { Write-Error "Chunk manifest not found: $ChunkManifest"; exit 2 }
$chunks = @(Get-Content -LiteralPath $ChunkManifest -Raw | ConvertFrom-Json)
if (-not $chunks) { Write-Error "Chunk manifest is empty."; exit 2 }

# Validate ids BEFORE any per-chunk work: each becomes a directory name joined to
# RunRoot. A separator or '..' would let a chunk write outside the run root; a
# duplicate id would make two chunks race on the same directory. Reject both.
$ids = @($chunks | ForEach-Object { $_.id })
# Slug-safe AND not a pure-dot id: '.' / '..' pass the character class but are
# directory-traversal handles ('..' would escape RunRoot), so reject them too. Also
# reject a trailing '.' or space: Windows silently strips those from a path segment,
# so 'C01.' and 'C01' would resolve to the SAME directory while reading as two
# distinct ids -- two chunks racing one dir, or a double-counted metrics.json.
$bad = @($ids | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+$' -or $_ -match '^\.+$' -or $_ -match '[. ]$' })
if ($bad) { Write-Error "Invalid chunk id(s) — must match [A-Za-z0-9._-], not be all dots, and not end in '.' or space: $($bad.ForEach({ "'$_'" }) -join ', ')"; exit 2 }
$dupes = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($dupes) { Write-Error "Duplicate chunk id(s): $($dupes -join ', ')"; exit 2 }

if (-not $RepoPath) {
    $top = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $top) { Write-Error 'Not in a git repo and no -RepoPath given.'; exit 2 }
    $RepoPath = $top.Trim()
}
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path

if (-not $RunRoot) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $RunRoot = Join-Path ([IO.Path]::GetTempPath()) (Join-Path 'adversarial-review' $stamp)
}
New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
$RunId = Split-Path -Leaf $RunRoot

Write-Host "Batch review: $($chunks.Count) chunks, batch-size $BatchSize"
Write-Host "RunRoot: $RunRoot"

# Clear each target chunk's previous metrics.json BEFORE any chunk runs. The chunk
# dir is reused (New-Item -Force below), which is exactly what a repair re-run hits:
# if a previous attempt left a metrics.json and this attempt dies before writing its
# own, the chunk would contribute the OLD attempt's numbers under a summary row that
# records THIS attempt's failure — and the "failed chunk(s) contribute no metrics"
# warning would be false (observed: a failed retry still contributing raised=99).
#
# Deliberately here, in the main scope, and NOT swallowed: $ErrorActionPreference is
# 'Stop', so a delete that cannot proceed (a locked file) aborts the batch before any
# expensive work, rather than leaving stale numbers to be counted. Skipping just the
# chunk would not be enough — the union below would keep its previous summary row and
# aggregate the stale file anyway. This is also why a chunk dir worth keeping must be
# backed up OUTSIDE the RunRoot before a retry, per the skill.
#
# Read every target's bytes into memory BEFORE deleting any of them, then restore
# whatever this loop already deleted if a later one fails. Deleting sequentially with
# no rollback meant a LATER locked file aborted the batch (correctly) but AFTER earlier
# chunks' stale metrics were already gone — destroying their data without this
# invocation ever getting to the fan-out that would have regenerated it.
$staleBackups = [ordered]@{}
foreach ($c in $chunks) {
    $stale = Join-Path (Join-Path $RunRoot $c.id) 'metrics.json'
    if (Test-Path -LiteralPath $stale) { $staleBackups[$stale] = [System.IO.File]::ReadAllBytes($stale) }
}
try {
    foreach ($stale in $staleBackups.Keys) { Remove-Item -LiteralPath $stale -Force }
} catch {
    # Attempt EVERY restore, don't stop at the first that fails: a later still-restorable
    # backup must not be abandoned because an earlier one couldn't be written. Collect any
    # restore failures and surface them alongside the original cleanup error, so the
    # operator sees the full picture (which chunks are now unrecoverable) rather than just
    # the first fault.
    $cleanupError = $_
    $restoreFailures = @()
    foreach ($stale in $staleBackups.Keys) {
        if (-not (Test-Path -LiteralPath $stale)) {
            try { [System.IO.File]::WriteAllBytes($stale, $staleBackups[$stale]) }
            catch { $restoreFailures += "$stale ($($_.Exception.Message))" }
        }
    }
    if ($restoreFailures) {
        throw "Stale-metrics cleanup failed ($($cleanupError.Exception.Message)) and these backups could NOT be restored: $($restoreFailures -join '; '). Those chunks' previous metrics are lost; recover them before aggregating."
    }
    throw $cleanupError
}

$results = $chunks | ForEach-Object -ThrottleLimit $BatchSize -Parallel {
    $c = $_
    $spine      = $using:spine
    $RunRoot    = $using:RunRoot
    $RepoPath   = $using:RepoPath
    $Target     = $using:Target
    $ContextPath = $using:ContextPath

    $chunkDir = Join-Path $RunRoot $c.id
    New-Item -ItemType Directory -Path $chunkDir -Force | Out-Null

    $a = @('-NoProfile', '-File', $spine, '-Target', $Target, '-RepoPath', $RepoPath, '-WorkDir', $chunkDir)
    if ($c.pathspec) { $a += @('-Pathspec', ((@($c.pathspec)) -join ';')) }
    foreach ($cp in @($ContextPath | Where-Object { $_ })) { $a += @('-ContextPath', $cp) }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = (& pwsh @a 2>&1 | Out-String)
    $sw.Stop()
    $exit = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $chunkDir 'run-output.txt') -Value $out -Encoding utf8

    [pscustomobject]@{
        chunkId = $c.id; label = $c.label; exitCode = $exit
        elapsedSec = [int]($sw.Elapsed.TotalSeconds); workDir = $chunkDir
        hasMetrics = (Test-Path -LiteralPath (Join-Path $chunkDir 'metrics.json'))
    }
}

$results = @($results) | Sort-Object chunkId

# Repairing a run means re-running this script into the SAME RunRoot with a subset
# manifest, so the chunks that already went well are kept. Each invocation writes
# its own per-PID batch-summary file, and aggregate-and-emit.ps1 reads all of them
# and unions by chunkId at aggregation time. This is safe under concurrent
# invocations: each writes a different file, so they never overwrite each other's
# data -- the race that lost concurrent invocations' chunks.
# Write this invocation's results to a per-invocation file. Concurrent
# batch-review.ps1 invocations each write their own file, so they never
# overwrite each other's data. aggregate-and-emit.ps1 reads every
# batch-summary.*.json file and unions them by chunkId at aggregation time.
#
# Write to a temp path first, then rename atomically: a killed process leaves
# no corrupt file (Set-Content truncates then writes, which would leave partial
# JSON on crash). The temp path is on the same volume, so the rename is atomic.
$partialPath = Join-Path $RunRoot "batch-summary.$PID.json"
$tempPartial = "$partialPath.tmp"
$results | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath $tempPartial -Encoding utf8
try {
    [System.IO.File]::Move($tempPartial, $partialPath, $true)
} catch {
    Remove-Item -LiteralPath $tempPartial -Force -ErrorAction SilentlyContinue
    throw
}

# Compute the set of all chunk ids across ALL invocations for the output message.
$carried = @()
$allChunkIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($sf in @(Get-ChildItem -LiteralPath $RunRoot -Filter 'batch-summary*.json' -File)) {
    try {
        foreach ($row in @(Get-Content -LiteralPath $sf.FullName -Raw | ConvertFrom-Json)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$row.chunkId)) { [void]$allChunkIds.Add([string]$row.chunkId) }
        }
    } catch { }
}
$carried = @($allChunkIds | Where-Object { $_ -notin @($results.chunkId) })
$runChunks = $allChunkIds.Count

$failed  = @($results | Where-Object { $_.exitCode -ne 0 })
$noMetrics = @($results | Where-Object { $_.exitCode -eq 0 -and -not $_.hasMetrics })

Write-Host ""
Write-Host "==== batch complete: $RunId ===="
$results | Format-Table chunkId, label, exitCode, elapsedSec, hasMetrics -AutoSize | Out-String | Write-Host
if ($carried) {
    Write-Host "Kept $($carried.Count) chunk(s) already in this RunRoot ($($carried -join ', ')) — the run now has $runChunks chunk(s) in total."
}
if ($failed)    { Write-Warning "$($failed.Count) chunk(s) failed: $($failed.chunkId -join ', ') — they contribute no metrics." }
if ($noMetrics) { Write-Warning "$($noMetrics.Count) chunk(s) left no metrics.json: $($noMetrics.chunkId -join ', ')." }
Write-Host ""
Write-Host "Next (host judgment, per the skill):"
Write-Host "  1. Adjudicate + verify each chunk -> report-<id>.md."
Write-Host "  2. §5 synthesise across chunks -> report.md; write $RunRoot\aggregate-verdict.json"
Write-Host "     (accepted per reviewer + judge participant)."
Write-Host "  3. pwsh -NoProfile -File `"$scriptDir\aggregate-and-emit.ps1`" -RunRoot `"$RunRoot`" -Repo <repo> [-Summary <name>]"
# `chunks` is what THIS invocation ran; `runChunks` is what the RunRoot now holds
# in total, which is the number aggregate-and-emit.ps1 will emit as ChunkCount.
[pscustomobject]@{ runRoot = $RunRoot; runId = $RunId; chunks = $results.Count; runChunks = $runChunks; failed = $failed.Count } | ConvertTo-Json -Compress
