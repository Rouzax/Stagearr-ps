#Requires -Version 5.1
<#
.SYNOPSIS
    Rerun functionality for Stagearr
.DESCRIPTION
    Interactive CLI for selecting and re-running completed or failed jobs.
    Displays a formatted job list, prompts for selection and confirmation,
    then dispatches the selected job via Start-SAWorker.
#>

function Get-SARerunJobList {
    <#
    .SYNOPSIS
        Gets completed and failed jobs sorted by date descending.
    .DESCRIPTION
        Fetches jobs from both the completed and failed queues, merges them,
        and returns them sorted by updatedAt descending (newest first).
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER Limit
        Maximum number of jobs to return (default: 10).
    .OUTPUTS
        Array of job hashtables sorted by updatedAt descending.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,

        [Parameter()]
        [int]$Limit = 10
    )

    $completedJobs = Get-SAJobs -QueueRoot $QueueRoot -State 'completed' -Limit $Limit
    $failedJobs = Get-SAJobs -QueueRoot $QueueRoot -State 'failed' -Limit $Limit

    # Merge both lists
    $allJobs = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($job in $completedJobs) {
        $allJobs.Add($job)
    }
    foreach ($job in $failedJobs) {
        $allJobs.Add($job)
    }

    if ($allJobs.Count -eq 0) {
        return @()
    }

    # Sort by updatedAt descending (ISO 8601 timestamps with RoundtripKind parsing)
    $sorted = $allJobs | Sort-Object -Property {
        try {
            [datetime]::Parse($_.updatedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch {
            [datetime]::MinValue
        }
    } -Descending

    # Truncate to limit
    if ($sorted.Count -gt $Limit) {
        $sorted = $sorted | Select-Object -First $Limit
    }

    return @($sorted)
}

function Invoke-SARerun {
    <#
    .SYNOPSIS
        Interactive CLI for re-running completed or failed jobs.
    .DESCRIPTION
        Displays a formatted table of recent completed and failed jobs,
        prompts the user to select one, and re-dispatches it for processing.
        Uses Write-Host for all display (interactive CLI, like -Setup).
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER Config
        Configuration hashtable.
    .PARAMETER Limit
        Maximum number of jobs to display (default: 10).
    .PARAMETER ProcessJob
        Script block to process each job. Passed through to Start-SAWorker.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter()]
        [int]$Limit = 10,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ProcessJob
    )

    $jobs = Get-SARerunJobList -QueueRoot $QueueRoot -Limit $Limit

    if ($jobs.Count -eq 0) {
        Write-Host "No completed or failed jobs found." -ForegroundColor Yellow
        return
    }

    # Display formatted table header
    Write-Host ""
    Write-Host ("{0,-4} {1,-10} {2,-16} {3,-10} {4}" -f '#', 'State', 'Date', 'Label', 'Name') -ForegroundColor Cyan
    Write-Host ("{0,-4} {1,-10} {2,-16} {3,-10} {4}" -f '--', '-----', '----', '-----', '----') -ForegroundColor DarkGray

    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $job = $jobs[$i]
        $num = $i + 1
        $state = $job.state
        $dateStr = ''
        try {
            $dateStr = ([datetime]::Parse(
                $job.updatedAt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )).ToLocalTime().ToString('dd-MM-yy HH:mm')
        } catch { }
        $label = $job.input.downloadLabel
        $name = Split-Path -Path $job.input.downloadPath -Leaf

        $color = if ($state -eq 'failed') { 'Red' } else { 'Green' }

        Write-Host ("{0,-4} " -f $num) -NoNewline
        Write-Host ("{0,-10} " -f $state) -ForegroundColor $color -NoNewline
        Write-Host ("{0,-16} {1,-10} {2}" -f $dateStr, $label, $name)
    }

    Write-Host ""

    # Read-Host loop for number selection
    while ($true) {
        $selection = Read-Host "Select job number (1-$($jobs.Count)), or 'q' to quit"

        if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq 'q') {
            return
        }

        $selNum = 0
        if (-not [int]::TryParse($selection, [ref]$selNum)) {
            Write-Host "Invalid input. Enter a number between 1 and $($jobs.Count)." -ForegroundColor Yellow
            continue
        }

        if ($selNum -lt 1 -or $selNum -gt $jobs.Count) {
            Write-Host "Invalid selection. Enter a number between 1 and $($jobs.Count)." -ForegroundColor Yellow
            continue
        }

        break
    }

    $selectedJob = $jobs[$selNum - 1]
    $selectedName = Split-Path -Path $selectedJob.input.downloadPath -Leaf

    Write-Host ""
    Write-Host "Selected: $selectedName" -ForegroundColor White

    $confirm = (Read-Host "Re-run this job? (y/n)").Trim().ToLower()
    if ($confirm -ne 'y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    # Build deferred job params with Force to allow re-creation
    $deferredParams = @{
        QueueRoot     = $QueueRoot
        DownloadPath  = $selectedJob.input.downloadPath
        DownloadLabel = $selectedJob.input.downloadLabel
        TorrentHash   = if ($selectedJob.input.torrentHash) { $selectedJob.input.torrentHash } else { '' }
        Force         = $true
    }

    if ($selectedJob.input.noCleanup) {
        $deferredParams['NoCleanup'] = $true
    }
    if ($selectedJob.input.noMail) {
        $deferredParams['NoMail'] = $true
    }

    Write-Host ""
    Write-Host "Re-running job..." -ForegroundColor Cyan

    Start-SAWorker -QueueRoot $QueueRoot -Config $Config -Wait -DeferredJobParams $deferredParams -ProcessJob $ProcessJob
}
