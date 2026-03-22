# -Rerun Interactive Job Re-runner Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `-Rerun` CLI flag that lists recent completed/failed jobs, lets the user pick one interactively, and re-runs it with `-Force -Wait`.

**Architecture:** New `Invoke-SARerun` public function in `Public/Rerun.ps1`. Uses `Get-SAJobs` to fetch jobs, `Write-Host` for the interactive table/prompts, then dispatches to the existing `Add-SAJob` + `Start-SAWorker` flow. New `Rerun` parameter set in `Stagearr.ps1`.

**Tech Stack:** PowerShell 5.1+, Pester 5 for tests

---

### Task 1: Create Invoke-SARerun with job listing

**Files:**
- Create: `Modules/Stagearr.Core/Public/Rerun.ps1`
- Test: `Tests/Rerun.Tests.ps1`

**Step 1: Write the failing test for job fetching and sorting**

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../Modules/Stagearr.Core/Stagearr.Core.psd1" -Force
}

Describe 'Invoke-SARerun' {
    Describe 'Get-SARerunJobList (internal helper)' {
        It 'merges completed and failed jobs sorted by date descending' {
            InModuleScope 'Stagearr.Core' {
                $queueRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-rerun-test-$(New-Guid)"
                New-Item -Path "$queueRoot/completed" -ItemType Directory -Force | Out-Null
                New-Item -Path "$queueRoot/failed" -ItemType Directory -Force | Out-Null

                # Create a completed job (older)
                $completedJob = @{
                    id        = 'aaaa1111bbbb2222'
                    version   = 1
                    createdAt = '2026-03-22T10:00:00Z'
                    updatedAt = '2026-03-22T10:05:00Z'
                    state     = 'completed'
                    attempts  = 1
                    lastError = $null
                    input     = @{
                        downloadPath  = 'C:\Downloads\Movie.2024'
                        downloadLabel = 'Movie'
                        torrentHash   = 'abc123'
                        noCleanup     = $false
                        noMail        = $false
                    }
                    result    = @{
                        exitReason  = 'Movie - Movie.2024'
                        logFile     = 'C:\Logs\test.log'
                        duration    = '05:23'
                        completedAt = '2026-03-22T10:05:00Z'
                    }
                }
                $completedJson = $completedJob | ConvertTo-Json -Depth 10
                $completedPath = Join-Path "$queueRoot/completed" 'aaaa1111bbbb2222.json'
                [System.IO.File]::WriteAllText($completedPath, $completedJson)
                # Set older write time
                (Get-Item $completedPath).LastWriteTime = (Get-Date).AddMinutes(-10)

                # Create a failed job (newer)
                $failedJob = @{
                    id        = 'cccc3333dddd4444'
                    version   = 1
                    createdAt = '2026-03-22T10:10:00Z'
                    updatedAt = '2026-03-22T10:15:00Z'
                    state     = 'failed'
                    attempts  = 1
                    lastError = 'Import failed'
                    input     = @{
                        downloadPath  = 'C:\Downloads\Show.S01E01'
                        downloadLabel = 'TV'
                        torrentHash   = 'def456'
                        noCleanup     = $false
                        noMail        = $false
                    }
                    result    = @{
                        exitReason  = 'TV - Show.S01E01'
                        logFile     = 'C:\Logs\test2.log'
                        duration    = '02:10'
                        completedAt = '2026-03-22T10:15:00Z'
                    }
                }
                $failedJson = $failedJob | ConvertTo-Json -Depth 10
                $failedPath = Join-Path "$queueRoot/failed" 'cccc3333dddd4444.json'
                [System.IO.File]::WriteAllText($failedPath, $failedJson)
                # Set newer write time
                (Get-Item $failedPath).LastWriteTime = (Get-Date).AddMinutes(-5)

                $jobs = Get-SARerunJobList -QueueRoot $queueRoot -Limit 10

                $jobs.Count | Should -Be 2
                # Failed job is newer, should be first
                $jobs[0].state | Should -Be 'failed'
                $jobs[1].state | Should -Be 'completed'

                Remove-Item -Path $queueRoot -Recurse -Force
            }
        }

        It 'respects the limit parameter' {
            InModuleScope 'Stagearr.Core' {
                $queueRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-rerun-test-$(New-Guid)"
                New-Item -Path "$queueRoot/completed" -ItemType Directory -Force | Out-Null
                New-Item -Path "$queueRoot/failed" -ItemType Directory -Force | Out-Null

                # Create 3 completed jobs
                for ($i = 1; $i -le 3; $i++) {
                    $job = @{
                        id        = "job{0:d16}" -f $i
                        version   = 1
                        createdAt = "2026-03-22T10:0${i}:00Z"
                        updatedAt = "2026-03-22T10:0${i}:30Z"
                        state     = 'completed'
                        attempts  = 1
                        lastError = $null
                        input     = @{
                            downloadPath  = "C:\Downloads\Movie$i"
                            downloadLabel = 'Movie'
                            torrentHash   = "hash$i"
                            noCleanup     = $false
                            noMail        = $false
                        }
                        result    = @{
                            completedAt = "2026-03-22T10:0${i}:30Z"
                        }
                    }
                    $json = $job | ConvertTo-Json -Depth 10
                    $path = Join-Path "$queueRoot/completed" "$($job.id).json"
                    [System.IO.File]::WriteAllText($path, $json)
                    (Get-Item $path).LastWriteTime = (Get-Date).AddMinutes(-$i)
                }

                $jobs = Get-SARerunJobList -QueueRoot $queueRoot -Limit 2
                $jobs.Count | Should -Be 2

                Remove-Item -Path $queueRoot -Recurse -Force
            }
        }

        It 'returns empty array when no jobs exist' {
            InModuleScope 'Stagearr.Core' {
                $queueRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-rerun-test-$(New-Guid)"
                New-Item -Path "$queueRoot/completed" -ItemType Directory -Force | Out-Null
                New-Item -Path "$queueRoot/failed" -ItemType Directory -Force | Out-Null

                $jobs = Get-SARerunJobList -QueueRoot $queueRoot -Limit 10
                $jobs.Count | Should -Be 0

                Remove-Item -Path $queueRoot -Recurse -Force
            }
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run: `pwsh -Command "Invoke-Pester Tests/Rerun.Tests.ps1 -Output Detailed"`
Expected: FAIL -- `Get-SARerunJobList` not found

**Step 3: Write the Rerun.ps1 with Get-SARerunJobList and Invoke-SARerun**

Create `Modules/Stagearr.Core/Public/Rerun.ps1`:

```powershell
function Get-SARerunJobList {
    <#
    .SYNOPSIS
        Gets completed and failed jobs merged and sorted for rerun selection.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER Limit
        Maximum number of jobs to return (default: 10).
    .OUTPUTS
        Array of job objects sorted by timestamp descending.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,

        [Parameter()]
        [int]$Limit = 10
    )

    $completed = @(Get-SAJobs -QueueRoot $QueueRoot -State 'completed' -Limit $Limit)
    $failed = @(Get-SAJobs -QueueRoot $QueueRoot -State 'failed' -Limit $Limit)

    $all = @($completed) + @($failed)

    if ($all.Count -eq 0) {
        return @()
    }

    # Sort by updatedAt descending, take limit
    $sorted = $all | Sort-Object -Property {
        try {
            [datetime]::Parse(
                $_.updatedAt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )
        } catch {
            [datetime]::MinValue
        }
    } -Descending | Select-Object -First $Limit

    return @($sorted)
}

function Invoke-SARerun {
    <#
    .SYNOPSIS
        Interactive job re-runner. Shows recent completed/failed jobs and lets user pick one to re-run.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER Config
        Configuration hashtable.
    .PARAMETER Limit
        Maximum number of jobs to display (default: 10).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter()]
        [int]$Limit = 10
    )

    $jobs = Get-SARerunJobList -QueueRoot $QueueRoot -Limit $Limit

    if ($jobs.Count -eq 0) {
        Write-Host "No completed or failed jobs found." -ForegroundColor Yellow
        return
    }

    # Display header
    Write-Host ""
    Write-Host ("  {0,-4} {1,-10} {2,-16} {3,-8} {4}" -f '#', 'State', 'Date', 'Label', 'Name') -ForegroundColor Cyan
    Write-Host ("  {0,-4} {1,-10} {2,-16} {3,-8} {4}" -f '--', '-----', '----', '-----', '----') -ForegroundColor DarkGray

    # Display job list
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $job = $jobs[$i]
        $num = $i + 1
        $name = Split-Path -Path $job.input.downloadPath -Leaf
        $label = $job.input.downloadLabel
        $state = $job.state.Substring(0, 1).ToUpper() + $job.state.Substring(1)

        # Parse timestamp for display
        $dateStr = ''
        $timestamp = if ($job.result -and $job.result.completedAt) { $job.result.completedAt } else { $job.updatedAt }
        if ($timestamp) {
            try {
                $dt = [datetime]::Parse(
                    $timestamp,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind
                )
                $dateStr = $dt.ToLocalTime().ToString('dd-MM-yy HH:mm')
            } catch { }
        }

        $stateColor = if ($job.state -eq 'failed') { 'Red' } else { 'Green' }

        Write-Host "  " -NoNewline
        Write-Host ("{0,-4}" -f $num) -NoNewline
        Write-Host ("{0,-10}" -f $state) -ForegroundColor $stateColor -NoNewline
        Write-Host ("{0,-16} {1,-8} {2}" -f $dateStr, $label, $name)
    }

    Write-Host ""

    # Input loop for job selection
    while ($true) {
        $input = Read-Host "Enter job number to re-run (or 'q' to quit)"
        $input = $input.Trim()

        if ($input -eq 'q' -or $input -eq '') {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }

        $num = 0
        if (-not [int]::TryParse($input, [ref]$num) -or $num -lt 1 -or $num -gt $jobs.Count) {
            Write-Host "Invalid selection. Enter 1-$($jobs.Count) or 'q' to quit." -ForegroundColor Yellow
            continue
        }

        $selectedJob = $jobs[$num - 1]
        $selectedName = Split-Path -Path $selectedJob.input.downloadPath -Leaf
        $selectedLabel = $selectedJob.input.downloadLabel

        # Confirmation
        $confirm = Read-Host "Re-run `"$selectedName`" [$selectedLabel]? (y/n)"
        if ($confirm.Trim().ToLower() -ne 'y') {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return
        }

        # Dispatch re-run using existing queue + worker infrastructure
        $jobParams = @{
            QueueRoot     = $QueueRoot
            DownloadPath  = $selectedJob.input.downloadPath
            DownloadLabel = $selectedJob.input.downloadLabel
            TorrentHash   = if ($selectedJob.input.torrentHash) { $selectedJob.input.torrentHash } else { '' }
            NoCleanup     = [bool]$selectedJob.input.noCleanup
            NoMail        = [bool]$selectedJob.input.noMail
            Force         = $true
        }

        Start-SAWorker -QueueRoot $QueueRoot -Config $Config -Wait `
            -Verbose:($VerbosePreference -eq 'Continue') `
            -DeferredJobParams $jobParams `
            -ProcessJob {
                param($Context, $Job)
                Invoke-SAJobProcessing -Context $Context -Job $Job
            }

        return
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `pwsh -Command "Invoke-Pester Tests/Rerun.Tests.ps1 -Output Detailed"`
Expected: All 3 tests PASS

**Step 5: Commit**

```bash
git add Modules/Stagearr.Core/Public/Rerun.ps1 Tests/Rerun.Tests.ps1
git commit -m "feat: add Invoke-SARerun and Get-SARerunJobList with tests"
```

---

### Task 2: Register Rerun.ps1 in module loader and exports

**Files:**
- Modify: `Modules/Stagearr.Core/Stagearr.Core.psm1:53-67` (PublicLoadOrder)
- Modify: `Modules/Stagearr.Core/Stagearr.Core.psd1:14-109` (FunctionsToExport)

**Step 1: Add Rerun.ps1 to PublicLoadOrder in psm1**

In `Stagearr.Core.psm1`, add `'Rerun.ps1'` to `$PublicLoadOrder` after `'Queue.ps1'` (it depends on Queue functions):

```powershell
$PublicLoadOrder = @(
    'Setup.ps1'
    'Lock.ps1'
    'Queue.ps1'
    'Rerun.ps1'              # Interactive job re-runner (depends on Queue)
    'Notification.ps1'
    # ... rest unchanged
)
```

**Step 2: Add exports to psd1**

In `Stagearr.Core.psd1`, add after the Queue operations section:

```powershell
        # --- Rerun ---
        'Invoke-SARerun'
```

Note: `Get-SARerunJobList` is an internal helper -- do NOT export it. It is accessible via `InModuleScope` for tests.

**Step 3: Verify module loads cleanly**

Run: `pwsh -Command "Import-Module ./Modules/Stagearr.Core/Stagearr.Core.psd1 -Force; Get-Command Invoke-SARerun"`
Expected: Shows `Invoke-SARerun` as a Function from `Stagearr.Core`

**Step 4: Run existing tests to verify no regressions**

Run: `pwsh -Command "Invoke-Pester Tests/ -Output Detailed"`
Expected: All tests pass (existing + new)

**Step 5: Commit**

```bash
git add Modules/Stagearr.Core/Stagearr.Core.psm1 Modules/Stagearr.Core/Stagearr.Core.psd1
git commit -m "feat: register Rerun.ps1 in module loader and exports"
```

---

### Task 3: Add -Rerun parameter set to Stagearr.ps1

**Files:**
- Modify: `Stagearr.ps1:94-132` (param block)
- Modify: `Stagearr.ps1:234-495` (switch block)

**Step 1: Add Rerun parameter set to param block**

Add after the `Update` parameter set (line ~128), before `[Parameter()] [string]$ConfigPath`:

```powershell
    [Parameter(ParameterSetName = 'Rerun', Position = 0)]
    [int]$Rerun = 10,
```

**Step 2: Add Rerun branch to the switch block**

Add a new case in the `switch ($PSCmdlet.ParameterSetName)` block (after `'Status'`, before `'Enqueue'`):

```powershell
    'Rerun' {
        Write-SAPhaseHeader -Title "Re-run Job"
        Invoke-SARerun -QueueRoot $Config.paths.queueRoot -Config $Config -Limit $Rerun
        exit 0
    }
```

**Step 3: Update script help block**

Add a new `.EXAMPLE` in the help comment block:

```powershell
.EXAMPLE
    # Interactively re-run a recent job:
    Stagearr.ps1 -Rerun

.EXAMPLE
    # Show last 20 jobs for re-run:
    Stagearr.ps1 -Rerun 20
```

**Step 4: Verify parameter set works**

Run: `pwsh -Command "Get-Help ./Stagearr.ps1 -Parameter Rerun"`
Expected: Shows the Rerun parameter with type Int32 and default 10

**Step 5: Commit**

```bash
git add Stagearr.ps1
git commit -m "feat: add -Rerun parameter set to CLI entrypoint"
```

---

### Task 4: Add display formatting test

**Files:**
- Modify: `Tests/Rerun.Tests.ps1`

**Step 1: Add test for Format-SARerunTable output**

We should also verify the display formatting works. Add to the existing test file, but since `Invoke-SARerun` is interactive (uses `Read-Host`), we test the helper `Get-SARerunJobList` more thoroughly and test that `Invoke-SARerun` handles the "no jobs" case:

```powershell
    Describe 'Invoke-SARerun edge cases' {
        It 'displays message and returns when no jobs exist' {
            InModuleScope 'Stagearr.Core' {
                $queueRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stagearr-rerun-test-$(New-Guid)"
                New-Item -Path "$queueRoot/completed" -ItemType Directory -Force | Out-Null
                New-Item -Path "$queueRoot/failed" -ItemType Directory -Force | Out-Null

                $config = @{ paths = @{ queueRoot = $queueRoot } }

                # Should return without prompting (no Read-Host call)
                Invoke-SARerun -QueueRoot $queueRoot -Config $config -Limit 10

                Remove-Item -Path $queueRoot -Recurse -Force
            }
        }
    }
```

**Step 2: Run all tests**

Run: `pwsh -Command "Invoke-Pester Tests/Rerun.Tests.ps1 -Output Detailed"`
Expected: All tests PASS

**Step 3: Run full test suite for regressions**

Run: `pwsh -Command "Invoke-Pester Tests/ -Output Detailed"`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add Tests/Rerun.Tests.ps1
git commit -m "test: add edge case tests for Invoke-SARerun"
```
