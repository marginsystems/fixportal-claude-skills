#Requires -Version 7
<#
.SYNOPSIS
    Aggregate a chunked/batched adversarial review into ONE per-participant
    outcome and emit it to the AI Observatory.

.DESCRIPTION
    A large diff is reviewed as N cohesive chunks, each a full panel run (see the
    skill, §0a / §5). Each chunk's run-review.ps1 leaves a `metrics.json` holding
    each reviewer's deterministic outcome (issuesRaised + cost + duration), one
    participant entry per manifest reviewer — summed per vendor here, so the two
    Anthropic reviewers (Fable + Sonnet) collapse into one anthropic row.
    Adjudication/synthesis is host judgment; its products — issuesAccepted per
    reviewer and the synthesis (judge) participant's cost — are recorded in an
    `aggregate-verdict.json` the host writes at §5 synthesis time.

    This script sums every chunk's `metrics.json` per participant, folds in the
    verdict, and calls emit-review-telemetry.ps1 ONCE per participant with the run
    totals and `-ChunkCount N`. The result is a single dashboard run whose four
    rows carry real summed numbers instead of placeholder zeros.

    Idempotent: re-running overwrites the same run's rows in place (the API upserts
    on (runId, reviewer, role)), so a run can be re-aggregated after more chunks
    complete or after the verdict is filled in.

    Silently no-ops emitting when OBSERVATORY_API_KEY / OBSERVATORY_URL are absent
    (emit-review-telemetry.ps1 handles that) but still prints the aggregate table.

.PARAMETER RunRoot
    The run's top working directory — the parent holding the per-chunk
    subdirectories (each with a metrics.json). Defaults to the current directory.

.PARAMETER RunId
    Shared run id for all participants (the run-root's UTC stamp). Defaults to the
    leaf name of RunRoot.

.PARAMETER Repo
    Repository name (basename of the repo root). Same value on every row.

.PARAMETER Summary
    Optional operator-assigned run name → dashboard card title.

.PARAMETER VerdictPath
    Path to aggregate-verdict.json. Defaults to <RunRoot>/aggregate-verdict.json.
    Shape:
      {
        "accepted": { "anthropic": 6, "google": 3, "openai": 4 },
        "judge": { "reviewer": "anthropic", "model": "claude-opus-4-8",
                   "inputTokens": 90000, "outputTokens": 0,
                   "costUsd": 2.7, "reviewDurationMs": 140000 }
      }
    Both keys optional. Missing `accepted` → zeros (warned). Missing `judge` → no
    judge row emitted (the run shows as "no judge").

.EXAMPLE
    pwsh -NoProfile -File aggregate-and-emit.ps1 -RunRoot <runRoot> -Repo your-repo -Summary 'Whole-repo audit'
#>
[CmdletBinding()]
param(
    [string] $RunRoot = '.',
    [string] $RunId,
    [string] $Repo,
    [string] $Summary,
    [string] $VerdictPath
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
$emit = Join-Path $scriptDir 'emit-review-telemetry.ps1'
# -ErrorAction Continue on every fatal Write-Error below: $ErrorActionPreference is
# 'Stop', under which Write-Error throws a terminating ActionPreferenceStopException
# and the `exit <n>` after it never runs — so each distinct exit code was dead and
# every failure surfaced as a bare exit 1. Print, then exit with the real code.
if (-not (Test-Path -LiteralPath $emit)) { Write-Error "emit-review-telemetry.ps1 not found beside this script." -ErrorAction Continue; exit 2 }

$RunRoot = (Resolve-Path -LiteralPath $RunRoot).Path
if (-not $RunId)       { $RunId = Split-Path -Leaf $RunRoot }
if (-not $VerdictPath) { $VerdictPath = Join-Path $RunRoot 'aggregate-verdict.json' }

# --- Collect per-chunk metrics ------------------------------------------
# batch-summary.*.json files (written by batch-review.ps1, one per invocation) are
# the source of truth for BOTH which chunks belong to this run and how many there
# were. We read all of them and union by chunkId (last writer wins for duplicates).
# A blind recursive scan of RunRoot would also pull in stale metrics.json left over
# from a reused run root and inflate the totals while ChunkCount came from the
# summary. Fall back to the recursive scan only for an ad-hoc batch that did not
# go through batch-review.ps1.
$summaryFiles = @(Get-ChildItem -LiteralPath $RunRoot -Filter 'batch-summary*.json' -File | Sort-Object Name)
if ($summaryFiles) {
    $mergedRows = [ordered]@{}
    foreach ($sf in $summaryFiles) {
        try {
            foreach ($row in @(Get-Content -LiteralPath $sf.FullName -Raw | ConvertFrom-Json)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$row.chunkId)) {
                    $mergedRows[$row.chunkId] = $row
                }
            }
        } catch { }
    }
    $summaryRows = @($mergedRows.Values) | Sort-Object chunkId

    # A run IS its set of distinct chunk ids. Resolve each chunk's metrics.json from
    # <RunRoot>/<chunkId> rather than from the row's persisted workDir: batch-review.ps1
    # does not resolve -RunRoot, so a relative one persists relative workDirs that
    # Test-Path silently misses when aggregation runs from a different directory, and
    # a temp path can be recorded in 8.3 short form. RunRoot is resolved above and a
    # chunkId is a slug (re-validated just below) naming a direct child, so this is
    # exact and path-form independent — while staying bounded by the summary, so a stale chunk
    # dir it does not name is still excluded (that inflation is why the summary is
    # authoritative rather than a blind scan). workDir stays informational only.
    # Keying by id also collapses a duplicate row, which would otherwise double-count
    # both ChunkCount and that chunk's metrics.
    #
    # Match the id comparison to the FILESYSTEM's case rule, not a fixed one. A chunk
    # id both names a summary row and (via Join-Path) a directory on disk, so the two
    # must agree on whether 'c01' and 'C01' are the same chunk exactly when the
    # filesystem does. A fixed OrdinalIgnoreCase is right on Windows/macOS but wrong
    # on a case-sensitive filesystem: it would resolve 'c01' to a 'C01' dir that
    # isn't really there (missing its metrics) while the orphan scan below, keyed by
    # the same set, treats the on-disk 'C01' as named -- so a short run emits instead
    # of being refused.
    #
    # Probe with a FRESH uniquely-named marker, not a case-flip of an existing file:
    # a fixed 'BATCH-SUMMARY.0.JSON' probe would read as case-insensitive if a distinct
    # all-caps file happened to exist beside the batch-summary files on a case-sensitive
    # volume. A guid name can't pre-exist, and the letter prefix guarantees its upper-
    # and lower-cased forms differ. If the probe can't be written, FAIL CLOSED rather
    # than guess from the OS: macOS can run a case-sensitive volume, so an OS guess of
    # case-insensitive there would collapse c01/C01, suppress the orphan guard, and
    # emit short totals -- exactly the bug this exists to stop. A wrong guess on a
    # correctness-critical comparison is worse than refusing; the operator makes
    # RunRoot writable (it is a live run's working dir) and re-runs.
    $probeName = "caseprobe-$([guid]::NewGuid().ToString('N'))"
    $probePath = Join-Path $RunRoot $probeName
    $fsCaseInsensitive = $null
    try {
        Set-Content -LiteralPath $probePath -Value '' -NoNewline -ErrorAction Stop
        $fsCaseInsensitive = Test-Path -LiteralPath (Join-Path $RunRoot $probeName.ToUpperInvariant())
    } catch {
        Write-Warning "Could not determine the filesystem's case rule under $RunRoot ($($_.Exception.Message)). Assuming case-sensitive (Ordinal) comparison; chunk ids differing only in case may appear as orphans. Make RunRoot writable and re-run for precise detection."
        $fsCaseInsensitive = $false
    } finally {
        if (Test-Path -LiteralPath $probePath) { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue }
    }
    $idComparer = if ($fsCaseInsensitive) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $summaryIds = [System.Collections.Generic.HashSet[string]]::new($idComparer)

    # A row with no chunkId can't be counted or resolved, so SKIPPING it (the old
    # behaviour) silently drops a chunk from ChunkCount with no orphan evidence — a
    # failed chunk left no metrics dir either, so nothing downstream can catch it.
    # Count such rows and reject the whole summary rather than quietly omit them.
    $rowsMissingId = @($summaryRows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.chunkId) }).Count
    foreach ($row in $summaryRows) {
        if (-not [string]::IsNullOrWhiteSpace([string]$row.chunkId)) { [void]$summaryIds.Add([string]$row.chunkId) }
    }

    # Re-validate every id against batch-review.ps1's slug rule before joining it into
    # a path. batch-review.ps1 validates ids it writes, but the skill's repair flow
    # tells operators to REBUILD the summary files by hand, so the files are not a
    # trusted source: a hand-written or corrupted id like '..\other' joins straight
    # into <RunRoot>\..\other\metrics.json, escaping RunRoot to aggregate an unrelated
    # file — and the orphan scan below misses it, because the resolved dir is not a
    # child of RunRoot at all. Same rule as batch-review.ps1 (slug chars, not all
    # dots, no trailing '.'/space -- Windows strips those, collapsing 'C01.' onto 'C01').
    $badIds = @($summaryIds | Where-Object { $_ -notmatch '^[A-Za-z0-9._-]+$' -or $_ -match '^\.+$' -or $_ -match '[. ]$' })
    if ($rowsMissingId -gt 0 -or $badIds) {
        $parts = @()
        if ($rowsMissingId -gt 0) { $parts += "$rowsMissingId row(s) with no chunkId" }
        if ($badIds)             { $parts += "invalid chunk id(s): $($badIds -join ', ')" }
        Write-Error "batch-summary files are malformed ($($parts -join '; ')). Every row must carry a chunkId matching [A-Za-z0-9._-] and not all dots (it names a direct child of RunRoot). Refusing to aggregate — rebuild the summary with valid ids." -ErrorAction Continue
        exit 5
    }

    $chunkCount  = $summaryIds.Count
    $metricFiles = @($summaryIds |
        ForEach-Object { Join-Path (Join-Path $RunRoot $_) 'metrics.json' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Get-Item -LiteralPath $_ })
    if ($chunkCount -gt $metricFiles.Count) {
        Write-Warning "$($chunkCount - $metricFiles.Count) chunk(s) left no metrics.json — counted in ChunkCount but contributing no metrics."
    }

    # A row that DECLARES failure (exitCode != 0 or hasMetrics = false) must have no
    # metrics.json on disk -- metrics are selected purely by chunkId, so a stale file
    # in a failed chunk's dir would otherwise be summed anyway, inflating the totals,
    # and the orphan scan would wave it through because the id IS named. Current runs
    # can't produce this (batch-review clears a chunk's metrics before a retry), but a
    # legacy or hand-repaired RunRoot can. The summary contradicting the disk is not
    # something to silently resolve in the inflating direction: refuse.
    $contradictions = @($summaryRows | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.chunkId) -and
        (($null -ne $_.hasMetrics -and $_.hasMetrics -eq $false) -or ($null -ne $_.exitCode -and [int]$_.exitCode -ne 0)) -and
        (Test-Path -LiteralPath (Join-Path (Join-Path $RunRoot ([string]$_.chunkId)) 'metrics.json'))
    })
    if ($contradictions) {
        $names = ($contradictions | ForEach-Object { $_.chunkId }) -join ', '
        Write-Error "batch-summary files mark these chunk(s) as failed (exitCode != 0 or hasMetrics = false) yet a metrics.json exists in their dir: $names. Counting it would inflate the totals; the summary and the filesystem disagree. Refusing to aggregate — remove the stale metrics.json or correct the row before re-running." -ErrorAction Continue
        exit 7
    }

    # A metrics.json under RunRoot the summary does NOT name means the summary is not
    # describing this run — it was truncated by a partial re-run before the per-invocation
    # file approach, or a chunk dir was hand-made or backed up inside the RunRoot.
    # Emitting anyway is the failure this
    # guard exists to stop: totals come out short and every `accepted` is clamped down
    # to match, so a broken run reads as a smaller but plausible one. The clamp
    # warnings below do fire, but they describe the consequence, not the cause.
    # Refuse — a confident wrong number is worse than no number. Requiring a direct
    # child AND a known id also catches a chunk dir backed up inside the RunRoot under
    # the id it copied.
    $orphans = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Filter 'metrics.json' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $chunkDir = Split-Path -Parent $_.FullName
            (Split-Path -Parent $chunkDir) -ne $RunRoot -or
            -not $summaryIds.Contains((Split-Path -Leaf $chunkDir))
        })
    if ($orphans) {
        $orphanDirs = ($orphans | ForEach-Object { '  ' + (Split-Path -Parent $_.FullName) }) -join [Environment]::NewLine
        Write-Error @"
batch-summary files name $chunkCount chunk(s), but $($orphans.Count) further metrics.json exist under this RunRoot that they do not name:
$orphanDirs
The summary is not describing this run, so ChunkCount and every per-vendor total would be short and every accepted count silently clamped to match. Refusing to emit. Fix by ONE of:
  - re-run batch-review.ps1 for the missing chunks into this RunRoot (it writes a new batch-summary.*.json); or
  - rebuild the batch-summary files from the chunk dirs; or
  - delete all batch-summary.*.json to aggregate every chunk dir under RunRoot instead
    (WARNING: the scan finds only chunks that left a metrics.json, so any FAILED
    chunk is silently dropped -- only do this when every chunk succeeded).
"@ -ErrorAction Continue
        exit 4
    }
} else {
    $metricFiles = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Filter 'metrics.json' -File -ErrorAction SilentlyContinue)
    $chunkCount  = $metricFiles.Count
}
if (-not $metricFiles) {
    Write-Error "No metrics.json found for $RunRoot. Each chunk's run-review.ps1 writes one; nothing to aggregate." -ErrorAction Continue
    exit 3
}

# Sum per reviewer vendor across chunks.
$byReviewer = @{}
foreach ($mf in $metricFiles) {
    $m = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json
    foreach ($p in @($m.participants)) {
        $key = $p.reviewer
        if (-not $byReviewer.ContainsKey($key)) {
            $byReviewer[$key] = [ordered]@{
                reviewer = $key; model = $p.model
                inputTokens = 0L; outputTokens = 0L; costUsd = 0.0
                reviewDurationMs = 0L; issuesRaised = 0; estimated = $false
            }
        }
        $acc = $byReviewer[$key]
        if (-not $acc.model -and $p.model) { $acc.model = $p.model }
        $acc.inputTokens      += [long]($p.inputTokens      ?? 0)
        $acc.outputTokens     += [long]($p.outputTokens     ?? 0)
        $acc.costUsd          += [double]($p.costUsd         ?? 0)
        $acc.reviewDurationMs += [long]($p.reviewDurationMs ?? 0)
        $acc.issuesRaised     += [int]($p.issuesRaised       ?? 0)
        if ($p.costEstimated)  { $acc.estimated = $true }
    }
}

# --- Verdict (accepted per reviewer + judge participant) ----------------
$accepted = @{}
$judge = $null
if (Test-Path -LiteralPath $VerdictPath) {
    $v = Get-Content -LiteralPath $VerdictPath -Raw | ConvertFrom-Json
    if ($v.accepted) {
        foreach ($prop in $v.accepted.PSObject.Properties) { $accepted[$prop.Name] = [int]$prop.Value }
    }
    if ($v.judge) { $judge = $v.judge }
} else {
    Write-Warning "No aggregate-verdict.json at $VerdictPath — issuesAccepted will be 0 and no judge row will be emitted. Write it at synthesis time (see the skill, §5)."
}

# --- Emit one participant at a time --------------------------------------
function Invoke-Emit([hashtable] $named) {
    $argList = @('-NoProfile', '-File', $emit)
    foreach ($k in $named.Keys) { $argList += @("-$k", "$($named[$k])") }
    & pwsh @argList
    if ($LASTEXITCODE -ne 0) { Write-Warning "emit failed for $($named.Reviewer)/$($named.Role) (exit $LASTEXITCODE)" }
}

$rows = @()
foreach ($key in $byReviewer.Keys) {
    $r = $byReviewer[$key]
    $acc = if ($accepted.ContainsKey($key)) { $accepted[$key] } else { 0 }
    # The API enforces accepted <= raised; clamp defensively so a verdict
    # attribution quirk cannot 400 the whole emit.
    if ($acc -gt $r.issuesRaised) {
        Write-Warning "accepted ($acc) > raised ($($r.issuesRaised)) for $key — clamping to raised."
        $acc = $r.issuesRaised
    }
    $named = @{
        RunId = $RunId; Reviewer = $key; Role = 'reviewer'; Model = $r.model
        InputTokens = $r.inputTokens; OutputTokens = $r.outputTokens
        CostUsd = [Math]::Round($r.costUsd, 6); ReviewDurationMs = $r.reviewDurationMs
        IssuesRaised = $r.issuesRaised; IssuesAccepted = $acc; ChunkCount = $chunkCount
    }
    if ($Repo)    { $named.Repo = $Repo }
    if ($Summary) { $named.Summary = $Summary }
    Invoke-Emit $named
    $rows += [pscustomobject]@{ Participant = "$key (reviewer)"; Model = $r.model; Raised = $r.issuesRaised; Accepted = $acc; Cost = [Math]::Round($r.costUsd,4); DurationMs = $r.reviewDurationMs; CostEst = $r.estimated }
}

if ($judge) {
    $named = @{
        RunId = $RunId; Reviewer = $judge.reviewer; Role = 'judge'; Model = $judge.model
        InputTokens = [long]($judge.inputTokens ?? 0); OutputTokens = [long]($judge.outputTokens ?? 0)
        CostUsd = [Math]::Round([double]($judge.costUsd ?? 0), 6); ReviewDurationMs = [long]($judge.reviewDurationMs ?? 0)
        IssuesRaised = 0; IssuesAccepted = 0; ChunkCount = $chunkCount
    }
    if ($Repo)    { $named.Repo = $Repo }
    if ($Summary) { $named.Summary = $Summary }
    Invoke-Emit $named
    $rows += [pscustomobject]@{ Participant = "$($judge.reviewer) (judge)"; Model = $judge.model; Raised = 0; Accepted = 0; Cost = [Math]::Round([double]($judge.costUsd ?? 0),4); DurationMs = [long]($judge.reviewDurationMs ?? 0); CostEst = $false }
}

Write-Host ""
Write-Host "==== aggregate-and-emit: $RunId ($chunkCount chunks) ===="
$rows | Format-Table -AutoSize | Out-String | Write-Host
if (-not $judge) { Write-Warning "No judge row — run shows as 'no judge' until aggregate-verdict.json carries a judge." }
