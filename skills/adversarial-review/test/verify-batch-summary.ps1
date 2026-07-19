$ErrorActionPreference = 'Stop'
<#
  The batch-summary.*.json files (one per batch-review.ps1 invocation) are the
  source of truth for WHICH chunks belong to a run.
  These tests pin the two halves of that contract:

    batch-review.ps1        must let a RunRoot accumulate chunks across repeated
                            invocations (a repair re-runs a subset into the same
                            RunRoot, and must not shrink the run to that subset);
    aggregate-and-emit.ps1  must refuse to emit when the summary does not name
                            every chunk on disk, rather than emitting short
                            totals with every accepted count clamped to match.

  No reviewer API calls and no cost: run-review.ps1 exits 2 at its git-work-tree
  check when handed a non-git -RepoPath, so each chunk fails fast while
  batch-review.ps1 still records its row and writes the summary — which is the
  code under test. Telemetry env vars are cleared so emit cannot post anywhere.
#>

$batch = Join-Path $PSScriptRoot '..\batch-review.ps1'
$agg   = Join-Path $PSScriptRoot '..\aggregate-and-emit.ps1'
foreach ($s in @($batch, $agg)) {
    if (-not (Test-Path -LiteralPath $s)) { throw "script under test not found: $s" }
}

$env:OBSERVATORY_API_KEY = ''
$env:OBSERVATORY_URL     = ''

$root = Join-Path ([IO.Path]::GetTempPath()) ('ar-batch-summary-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fakeRepo = Join-Path $root 'not-a-repo'
New-Item -ItemType Directory -Path $fakeRepo -Force | Out-Null

try {
    function New-Manifest([string] $path, [string[]] $ids, [string] $labelPrefix = 'chunk') {
        @($ids | ForEach-Object { [pscustomobject]@{ id = $_; label = "$labelPrefix $_" } }) |
            ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath $path -Encoding utf8
    }
    function Get-SummaryIds([string] $runRoot) {
        $ids = @()
        foreach ($sf in @(Get-ChildItem -LiteralPath $runRoot -Filter 'batch-summary*.json' -File | Sort-Object Name)) {
            try {
                foreach ($row in @(Get-Content -LiteralPath $sf.FullName -Raw | ConvertFrom-Json)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$row.chunkId)) { $ids += $row.chunkId }
                }
            } catch { }
        }
        return @($ids | Sort-Object -Unique)
    }

    # --- batch-review.ps1 unions the summary across invocations ---------------
    $runRoot = Join-Path $root 'run1'
    $m1 = Join-Path $root 'm1.json'; New-Manifest $m1 @('C01', 'C02', 'C03')
    # The repair labels C02 differently so the merge's last-write-wins half is
    # observable: with identical payloads, keeping the STALE C02 row looks the same
    # as replacing it, and only the id set would be checked.
    $m2 = Join-Path $root 'm2.json'; New-Manifest $m2 @('C02') 'repair'

    & pwsh -NoProfile -File $batch -ChunkManifest $m1 -RepoPath $fakeRepo -RunRoot $runRoot -BatchSize 3 *>$null
    if ($LASTEXITCODE -ne 0) { throw "first batch invocation exited $LASTEXITCODE" }
    $ids = Get-SummaryIds $runRoot
    if (($ids -join ',') -ne 'C01,C02,C03') { throw "first invocation should record all 3 chunks, got '$($ids -join ',')'" }

    # The repair: re-run ONLY C02 into the same RunRoot, keeping the good chunks.
    # Each invocation writes its own per-PID file, so aggregate-and-emit.ps1 reads
    # all files and unions by chunkId -- later invocations' rows win for duplicates.
    & pwsh -NoProfile -File $batch -ChunkManifest $m2 -RepoPath $fakeRepo -RunRoot $runRoot -BatchSize 1 *>$null
    if ($LASTEXITCODE -ne 0) { throw "repair batch invocation exited $LASTEXITCODE" }
    $ids = Get-SummaryIds $runRoot
    if (($ids -join ',') -ne 'C01,C02,C03') { throw "repair re-run must keep the untouched chunks, got '$($ids -join ',')'" }

    # ...and the retried chunk must be the REPAIRED row, exactly once.
    $rows = @()
    $mRows = [ordered]@{}
    foreach ($sf in @(Get-ChildItem -LiteralPath $runRoot -Filter 'batch-summary*.json' -File | Sort-Object Name)) {
        foreach ($row in @(Get-Content -LiteralPath $sf.FullName -Raw | ConvertFrom-Json)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$row.chunkId)) { $mRows[$row.chunkId] = $row }
        }
    }
    $rows = @($mRows.Values)
    $c02  = @($rows | Where-Object { $_.chunkId -eq 'C02' })
    if ($c02.Count -ne 1) { throw "the union must leave C02 exactly once, got $($c02.Count) row(s)" }
    if ($c02[0].label -ne 'repair C02') { throw "the repair invocation must win for C02, got label '$($c02[0].label)'" }
    "batch-review.ps1 OK — a repair re-run preserves the run's other chunks and wins for the one it retried"

    # --- a FAILED retry must not inherit the previous attempt's metrics -------
    # The chunk dir is reused (New-Item -Force), so without clearing it a retry that
    # dies before writing its own metrics.json leaves the earlier attempt's numbers
    # in place. They then get aggregated under a summary row that records the retry
    # as FAILED, and the "failed chunk(s) contribute no metrics" warning is false.
    $runRoot4 = Join-Path $root 'run4'
    New-Item -ItemType Directory -Path (Join-Path $runRoot4 'C01') -Force | Out-Null
    [ordered]@{
        participants = @(
            [ordered]@{ reviewer = 'anthropic'; model = 'stale'; inputTokens = 1; outputTokens = 1
                        costUsd = 0.5; reviewDurationMs = 1; issuesRaised = 99 }
        )
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runRoot4 'C01\metrics.json') -Encoding utf8

    $m4 = Join-Path $root 'm4.json'; New-Manifest $m4 @('C01')
    & pwsh -NoProfile -File $batch -ChunkManifest $m4 -RepoPath $fakeRepo -RunRoot $runRoot4 -BatchSize 1 *>$null
    if ($LASTEXITCODE -ne 0) { throw "retry batch invocation exited $LASTEXITCODE" }
    if (Test-Path -LiteralPath (Join-Path $runRoot4 'C01\metrics.json')) {
        throw "a retry that wrote no metrics.json must not leave the previous attempt's behind"
    }
    $merged4 = [ordered]@{}
    foreach ($sf4 in @(Get-ChildItem -LiteralPath $runRoot4 -Filter 'batch-summary*.json' -File | Sort-Object Name)) {
        foreach ($row in @(Get-Content -LiteralPath $sf4.FullName -Raw | ConvertFrom-Json)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$row.chunkId)) { $merged4[$row.chunkId] = $row }
        }
    }
    $row4 = @($merged4.Values)[0]
    # exitCode first: without it the hasMetrics assertion is vacuous if the retry
    # somehow SUCCEEDED (nothing to inherit). Compare hasMetrics against $false
    # explicitly rather than testing truthiness, which also passes when the property
    # is absent entirely.
    if ($row4.exitCode -eq 0) { throw "the retry was supposed to fail; exitCode was 0, so this case proves nothing" }
    if ($row4.hasMetrics -ne $false) { throw "summary must record hasMetrics=false for a retry that produced none, got '$($row4.hasMetrics)'" }
    "batch-review.ps1 OK — a failed retry contributes nothing, rather than the previous attempt's numbers"

    # --- an aborted cleanup pass must not destroy chunks it didn't reach --------
    # The stale-metrics clear runs sequentially over every chunk in THIS invocation's
    # manifest, before any of them are re-run. If a later chunk's file is locked, the
    # batch aborts (correctly) -- but an EARLIER chunk's stale metrics must survive, or
    # a later retry with just that chunk finds a clean slate no one ever regenerated:
    # data destroyed by a cleanup pass that never got to redo the work.
    #
    # Windows-only: the fault injection is an open FileShare.Read handle blocking
    # Remove-Item, which is Win32 share-mode semantics. POSIX unlink() can remove a
    # directory entry out from under an open file descriptor, so the same lock would
    # not force a delete failure on Linux/macOS -- $code6 would stay 0 and the
    # assertion below would wrongly fail a working system, not catch a broken one.
    if ($IsWindows) {
        $runRoot6 = Join-Path $root 'run6'
        foreach ($id in @('C01', 'C02')) {
            New-Item -ItemType Directory -Path (Join-Path $runRoot6 $id) -Force | Out-Null
            "old-$id" | Set-Content -LiteralPath (Join-Path $runRoot6 "$id\metrics.json") -Encoding utf8
        }
        # The code under test round-trips raw bytes (ReadAllBytes / WriteAllBytes), so
        # compare bytes here too -- Get-Content -Raw decodes to a string first, which
        # would mask an encoding-level regression (e.g. a dropped/added BOM) that still
        # decodes to the same text.
        $c01Path = Join-Path $runRoot6 'C01\metrics.json'
        $c01Before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($c01Path))
        $m6 = Join-Path $root 'm6.json'; New-Manifest $m6 @('C01', 'C02')

        # C01 sorts first and would be cleared first; lock C02's stale file so ITS clear
        # fails, and check that C01's survives the abort anyway. FileShare.Read, not
        # None: None would also block the pre-delete ReadAllBytes backup, so the fault
        # fires before any deletion is even attempted and the rollback path is never
        # actually reached -- Read allows the backup to succeed while still blocking
        # Remove-Item, so this exercises the real rollback, not a different early exit.
        $fs = [System.IO.File]::Open((Join-Path $runRoot6 'C02\metrics.json'), 'Open', 'Read', 'Read')
        try {
            & pwsh -NoProfile -File $batch -ChunkManifest $m6 -RepoPath $fakeRepo -RunRoot $runRoot6 -BatchSize 1 *>$null
            $code6 = $LASTEXITCODE
        } finally { $fs.Close() }
        if ($code6 -eq 0) { throw "a locked stale metrics.json should abort the batch, exited 0" }
        if (-not (Test-Path -LiteralPath (Join-Path $runRoot6 'C01\metrics.json'))) {
            throw "C01's stale metrics must survive an abort caused by C02's locked file, not be destroyed"
        }
        # Presence alone doesn't prove the restore is correct -- an empty or truncated
        # write-back would also pass an existence check. Compare the actual bytes.
        $c01After = [Convert]::ToBase64String([IO.File]::ReadAllBytes($c01Path))
        if ($c01After -ne $c01Before) {
            throw "C01's stale metrics must be restored unchanged after the abort"
        }
        "batch-review.ps1 OK — an aborted cleanup pass restores chunks it already cleared, rather than destroying them"
    } else {
        "batch-review.ps1 SKIPPED — rollback-on-abort fault injection needs Windows file-share semantics"
    }

    # batch-summary.*.json's write-then-rename (batch-review.ps1) is
    # deliberately NOT covered by a test here. The property it defends -- a process
    # dying between truncate and write-complete must not leave a corrupted summary
    # -- can only be faked by locking the destination, and Windows then refuses to
    # even OPEN the file for either a direct Set-Content or the atomic replace, so
    # the file is left untouched either way. Tried it, watched it pass against the
    # pre-fix code too: a check that cannot fail is not evidence, so it is not
    # kept here. The fix stands on the reasoning ([System.IO.File]::Move with
    # overwrite is the documented same-volume atomic replace), not on a fabricated
    # regression test.

    # --- aggregate-and-emit.ps1 refuses a summary that misses chunks ----------
    $runRoot2 = Join-Path $root 'run2'
    foreach ($id in @('C01', 'C02', 'C03')) {
        $d = Join-Path $runRoot2 $id
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [ordered]@{
            participants = @(
                [ordered]@{ reviewer = 'anthropic'; model = 'claude-opus-4-8'; inputTokens = 1000
                            outputTokens = 100; costUsd = 0.5; reviewDurationMs = 1000; issuesRaised = 8 }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $d 'metrics.json') -Encoding utf8
    }
    function New-Summary([string] $runRoot, [string[]] $ids) {
        @($ids | ForEach-Object {
            [pscustomobject]@{ chunkId = $_; label = "chunk $_"; exitCode = 0; elapsedSec = 1
                               workDir = (Join-Path $runRoot $_); hasMetrics = $true }
        }) | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath (Join-Path $runRoot 'batch-summary.json') -Encoding utf8
    }

    New-Summary $runRoot2 @('C03')
    $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot2 -Repo test-repo 2>&1 | Out-String)
    # Assert the SPECIFIC code, not merely non-zero: under $ErrorActionPreference
    # 'Stop' a bare Write-Error throws before its `exit <n>` runs, which silently
    # collapses every distinct exit code to 1. A -ne 0 check cannot see that.
    if ($LASTEXITCODE -ne 4) { throw "a summary naming 1 of 3 chunks on disk must refuse with exit 4, got $LASTEXITCODE`n$out" }
    if ($out -notmatch 'does not name') { throw "refusal should name the unlisted chunks, got:`n$out" }
    # Pin the orphan SET, not just the phrase: 'does not name' appears whichever
    # chunks the guard picked, so on its own it cannot tell a correct refusal from
    # one reporting the wrong dirs. C01/C02 are unlisted; C03 the summary does name
    # and must not be reported -- that exclusion is what makes the set exact.
    foreach ($orphan in @('C01', 'C02')) {
        if ($out -notmatch "\b$orphan\b") { throw "refusal must name the unlisted chunk $orphan, got:`n$out" }
    }
    if ($out -match '\bC03\b') { throw "C03 is named by the summary and must not be reported unlisted, got:`n$out" }

    # And the honest case still emits, with the run's true totals (3 chunks x 8 raised).
    New-Summary $runRoot2 @('C01', 'C02', 'C03')
    $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot2 -Repo test-repo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "a summary naming every chunk must emit, exited $LASTEXITCODE`n$out" }
    if ($out -notmatch '\(3 chunks\)') { throw "ChunkCount must be the true number of chunks, got:`n$out" }
    if ($out -notmatch '\b24\b') { throw "issuesRaised must sum across chunks (3 x 8 = 24), got:`n$out" }
    "aggregate-and-emit.ps1 OK — refuses a truncated summary, sums the true run when honest"

    # --- the summary's workDir path form must not decide what is found --------
    # batch-review.ps1 does not resolve -RunRoot, so a relative one persists
    # relative workDirs (a temp path can also be recorded 8.3-short). Selecting
    # metrics via workDir then resolves them against the AGGREGATOR's working
    # directory, finding nothing when it differs. Chunk ids are resolved against
    # the resolved RunRoot instead, so path form cannot matter.
    $runRoot3 = Join-Path $root 'run3'
    foreach ($id in @('C01', 'C02', 'C03')) {
        $d = Join-Path $runRoot3 $id
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [ordered]@{
            participants = @(
                [ordered]@{ reviewer = 'anthropic'; model = 'claude-opus-4-8'; inputTokens = 1000
                            outputTokens = 100; costUsd = 0.5; reviewDurationMs = 1000; issuesRaised = 8 }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $d 'metrics.json') -Encoding utf8
    }
    @('C01', 'C02', 'C03') | ForEach-Object {
        [pscustomobject]@{ chunkId = $_; label = "chunk $_"; exitCode = 0; elapsedSec = 1
                           workDir = ".\run3\$_"; hasMetrics = $true }
    } | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath (Join-Path $runRoot3 'batch-summary.json') -Encoding utf8

    # Aggregate from a directory those relative workDirs cannot resolve against.
    $elsewhere = Join-Path $root 'elsewhere'
    New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
    Push-Location $elsewhere
    try {
        $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot3 -Repo test-repo 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    if ($code -ne 0) { throw "relative workDirs must not stop the run being found, exited $code`n$out" }
    if ($out -notmatch '\(3 chunks\)') { throw "expected all 3 chunks despite relative workDirs, got:`n$out" }
    if ($out -notmatch '\b24\b') { throw "expected summed raised=24 despite relative workDirs, got:`n$out" }
    "aggregate-and-emit.ps1 OK — chunk ids resolve against RunRoot, so workDir path form is irrelevant"

    # --- a hand-rebuilt summary can't traverse out of RunRoot -----------------
    # The repair flow tells operators to rebuild the batch-summary files by hand, so
    # their chunkIds are untrusted. A '..<sep>escape' id would otherwise join into a path
    # outside RunRoot and aggregate an unrelated metrics.json, invisibly to the
    # orphan scan (the resolved dir isn't a child of RunRoot). It must be refused.
    # Build the id with the platform separator so it is a REAL parent-ref on POSIX
    # too -- a hardcoded '..\outside' is just a literal filename on Linux/macOS, so
    # the test would pass there for the wrong reason (bad char, not traversal).
    $sep = [IO.Path]::DirectorySeparatorChar
    $runRoot7 = Join-Path $root 'run7'
    $outsideDir = Join-Path $root 'outside'
    New-Item -ItemType Directory -Path $runRoot7 -Force | Out-Null
    New-Item -ItemType Directory -Path $outsideDir -Force | Out-Null
    [ordered]@{ participants = @([ordered]@{ reviewer = 'anthropic'; model = 'm'; inputTokens = 1
                outputTokens = 1; costUsd = 9.99; reviewDurationMs = 1; issuesRaised = 42 }) } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $outsideDir 'metrics.json') -Encoding utf8
    @([pscustomobject]@{ chunkId = "..${sep}outside"; label = 'x'; exitCode = 0; elapsedSec = 1; workDir = 'x'; hasMetrics = $true }) |
        ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $runRoot7 'batch-summary.json') -Encoding utf8
    $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot7 -Repo test-repo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 5) { throw "a traversal chunk id must refuse with exit 5, got $LASTEXITCODE`n$out" }
    if ($out -match '\b42\b') { throw "the outside metrics.json must never be aggregated, but its issuesRaised leaked, got:`n$out" }
    "aggregate-and-emit.ps1 OK — a hand-rebuilt summary with a traversal id is refused, not followed out of RunRoot"

    # --- a row with no chunkId is rejected, not silently dropped ---------------
    # A chunkId-less row can't be counted or resolved. Skipping it would drop that
    # chunk from ChunkCount with no orphan evidence (a failed chunk left no metrics
    # dir either). The whole summary must be refused instead.
    # C01 gets a real metrics dir so the run is otherwise valid -- the ONLY defect is
    # the id-less row. Without the fix that row is dropped and the run emits cleanly
    # (exit 0), which is the silent loss; with it the summary is refused (exit 5).
    $runRoot11 = Join-Path $root 'run11'
    $d11 = Join-Path $runRoot11 'C01'; New-Item -ItemType Directory -Path $d11 -Force | Out-Null
    [ordered]@{ participants = @([ordered]@{ reviewer = 'anthropic'; model = 'm'; inputTokens = 1
                outputTokens = 1; costUsd = 0.1; reviewDurationMs = 1; issuesRaised = 3 }) } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $d11 'metrics.json') -Encoding utf8
    @(
        [pscustomobject]@{ chunkId = 'C01'; label = 'one'; exitCode = 0; elapsedSec = 1; workDir = 'x'; hasMetrics = $true }
        [pscustomobject]@{ label = 'no-id'; exitCode = 1; elapsedSec = 1; workDir = 'x'; hasMetrics = $false }
    ) | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath (Join-Path $runRoot11 'batch-summary.json') -Encoding utf8
    $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot11 -Repo test-repo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 5) { throw "a summary row with no chunkId must refuse with exit 5, got $LASTEXITCODE`n$out" }
    if ($out -notmatch 'no chunkId') { throw "the refusal should call out the missing chunkId, got:`n$out" }
    "aggregate-and-emit.ps1 OK — a row with no chunkId is refused, not silently dropped"

    # --- a trailing-dot chunk id is rejected ----------------------------------
    # Windows strips a trailing '.'/space from a path segment, so 'C01.' and 'C01'
    # collapse onto one dir while reading as two ids -- a double-count vector.
    $runRoot12 = Join-Path $root 'run12'
    New-Item -ItemType Directory -Path $runRoot12 -Force | Out-Null
    @([pscustomobject]@{ chunkId = 'C01.'; label = 'x'; exitCode = 0; elapsedSec = 1; workDir = 'x'; hasMetrics = $true }) |
        ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $runRoot12 'batch-summary.json') -Encoding utf8
    $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot12 -Repo test-repo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 5) { throw "a trailing-dot chunk id must refuse with exit 5, got $LASTEXITCODE`n$out" }
    "aggregate-and-emit.ps1 OK — a trailing-dot chunk id (Windows path collapse) is rejected"

    # --- a failed row must not carry stale metrics ----------------------------
    # A row marked failed (exitCode != 0 / hasMetrics = false) with a metrics.json in
    # its dir is a summary/disk contradiction: counting it inflates totals. Refuse.
    $runRoot13 = Join-Path $root 'run13'
    $d13 = Join-Path $runRoot13 'C01'; New-Item -ItemType Directory -Path $d13 -Force | Out-Null
    [ordered]@{ participants = @([ordered]@{ reviewer = 'anthropic'; model = 'm'; inputTokens = 1
                outputTokens = 1; costUsd = 0.1; reviewDurationMs = 1; issuesRaised = 99 }) } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $d13 'metrics.json') -Encoding utf8
    @([pscustomobject]@{ chunkId = 'C01'; label = 'x'; exitCode = 1; elapsedSec = 1; workDir = 'x'; hasMetrics = $false }) |
        ConvertTo-Json -AsArray | Set-Content -LiteralPath (Join-Path $runRoot13 'batch-summary.json') -Encoding utf8
    $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot13 -Repo test-repo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 7) { throw "a failed row with stale metrics must refuse with exit 7, got $LASTEXITCODE`n$out" }
    if ($out -match '\b99\b' -and $out -notmatch 'failed') { throw "the stale issuesRaised=99 must not be aggregated, got:`n$out" }
    "aggregate-and-emit.ps1 OK — a failed row carrying stale metrics is refused, not counted"

    # --- id matching follows the filesystem's case rule -----------------------
    # Only meaningful on a case-SENSITIVE filesystem: where 'c01' and 'C01' are the
    # same path (Windows/macOS), there is no mismatch to catch and the scenario
    # cannot arise. On a case-sensitive FS a summary naming 'c01' beside an on-disk
    # 'C01' dir must not silently emit a short run -- the id comparer must treat them
    # as distinct (so 'c01' misses its metrics AND the on-disk 'C01' reads as an
    # unnamed orphan), producing the loud refusal instead. Probe the temp FS the
    # same collision-safe way the fix does: a fresh uniquely-named marker.
    $runRoot10 = Join-Path $root 'run10'
    New-Item -ItemType Directory -Path $runRoot10 -Force | Out-Null
    $probe10 = "caseprobe-$([guid]::NewGuid().ToString('N'))"
    Set-Content -LiteralPath (Join-Path $runRoot10 $probe10) -Value '' -NoNewline
    $tmpFsCaseInsensitive = Test-Path -LiteralPath (Join-Path $runRoot10 $probe10.ToUpperInvariant())
    Remove-Item -LiteralPath (Join-Path $runRoot10 $probe10) -Force -ErrorAction SilentlyContinue
    if (-not $tmpFsCaseInsensitive) {
        foreach ($id in @('C01', 'C02')) {
            $d = Join-Path $runRoot10 $id
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            [ordered]@{ participants = @([ordered]@{ reviewer = 'anthropic'; model = 'm'; inputTokens = 1
                        outputTokens = 1; costUsd = 0.1; reviewDurationMs = 1; issuesRaised = 5 }) } |
                ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $d 'metrics.json') -Encoding utf8
        }
        # Summary names c01 (lower) where the dir is C01 (upper) -- a hand-edit case slip.
        @('c01', 'C02' | ForEach-Object {
            [pscustomobject]@{ chunkId = $_; label = "chunk $_"; exitCode = 0; elapsedSec = 1; workDir = 'x'; hasMetrics = $true }
        }) | ConvertTo-Json -Depth 5 -AsArray | Set-Content -LiteralPath (Join-Path $runRoot10 'batch-summary.json') -Encoding utf8
        $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot10 -Repo test-repo 2>&1 | Out-String)
        # Exit 4 specifically (the orphan refusal), not merely non-zero -- a parse or
        # runtime error would also be non-zero and would pass a bare check while
        # meaning something else. The on-disk 'C01' the summary's 'c01' failed to
        # match must be the one named as the orphan.
        if ($LASTEXITCODE -ne 4) { throw "a c01/C01 mismatch must refuse with exit 4 (orphan), got $LASTEXITCODE`n$out" }
        if ($out -notmatch '\bC01\b') { throw "the refusal must name the on-disk C01 as the unlisted orphan, got:`n$out" }
        "aggregate-and-emit.ps1 OK — id matching honours a case-sensitive filesystem"
    } else {
        "aggregate-and-emit.ps1 SKIPPED — case-mismatch test needs a case-sensitive filesystem"
    }

    # --- the distinct fatal exit codes stay distinct --------------------------
    # Same failure mode the exit-4 case guards: a bare Write-Error under
    # $ErrorActionPreference 'Stop' throws before its `exit <n>`, collapsing the
    # code to 1. Pin 2 (emitter missing) and 3 (no metrics) too, so dropping an
    # -ErrorAction Continue is caught rather than silently reverting the code.
    $runRoot8 = Join-Path $root 'run8'
    New-Item -ItemType Directory -Path $runRoot8 -Force | Out-Null
    # exit 3: a RunRoot with no batch-summary files and no metrics.json anywhere.
    $out = (& pwsh -NoProfile -File $agg -RunRoot $runRoot8 -Repo test-repo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 3) { throw "an empty RunRoot must exit 3 (no metrics to aggregate), got $LASTEXITCODE`n$out" }

    # exit 2: emit-review-telemetry.ps1 missing beside the script. Copy the aggregator
    # to a lone dir with a valid run so it gets past arg parsing to the emitter check.
    $isolated = Join-Path $root 'isolated'
    New-Item -ItemType Directory -Path $isolated -Force | Out-Null
    Copy-Item -LiteralPath $agg -Destination (Join-Path $isolated 'aggregate-and-emit.ps1')
    $runRoot9 = Join-Path $root 'run9'
    $d9 = Join-Path $runRoot9 'C01'; New-Item -ItemType Directory -Path $d9 -Force | Out-Null
    [ordered]@{ participants = @([ordered]@{ reviewer = 'anthropic'; model = 'm'; inputTokens = 1
                outputTokens = 1; costUsd = 0.1; reviewDurationMs = 1; issuesRaised = 1 }) } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $d9 'metrics.json') -Encoding utf8
    New-Summary $runRoot9 @('C01')
    $out = (& pwsh -NoProfile -File (Join-Path $isolated 'aggregate-and-emit.ps1') -RunRoot $runRoot9 -Repo test-repo 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 2) { throw "a missing emit-review-telemetry.ps1 must exit 2, got $LASTEXITCODE`n$out" }
    "aggregate-and-emit.ps1 OK — exit codes 2 (no emitter) and 3 (no metrics) stay distinct from 1"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
