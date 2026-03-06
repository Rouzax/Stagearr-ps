#Requires -Version 5.1
<#
.SYNOPSIS
    Job queue management for Stagearr
.DESCRIPTION
    File-backed durable job queue. Jobs are stored as JSON files and moved
    between folders (pending/running/completed/failed) to track state.
#>

function Add-SAJob {
    <#
    .SYNOPSIS
        Enqueues a new job for processing.
    .DESCRIPTION
        Creates a job file in the pending queue. Validates inputs and
        generates a deterministic job ID to prevent duplicates.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER DownloadPath
        Path to the downloaded torrent.
    .PARAMETER DownloadLabel
        Label for the download (e.g., TV, Movie).
    .PARAMETER TorrentHash
        Torrent hash (optional but recommended).
    .PARAMETER NoCleanup
        Skip staging cleanup after processing.
    .PARAMETER NoMail
        Skip email notification.
    .OUTPUTS
        Job object if created, $null if duplicate or skip.
    .EXAMPLE
        $job = Add-SAJob -QueueRoot "C:\Queue" -DownloadPath "C:\Downloads\Movie" -DownloadLabel "Movie" -TorrentHash "ABC123"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,
        
        [Parameter(Mandatory = $true)]
        [string]$DownloadPath,
        
        [Parameter()]
        [string]$DownloadLabel = '',
        
        [Parameter()]
        [string]$TorrentHash = '',
        
        [Parameter()]
        [switch]$NoCleanup,
        
        [Parameter()]
        [switch]$NoMail,
        
        [Parameter()]
        [switch]$Force
    )
    
    # Normalize label
    if ([string]::IsNullOrWhiteSpace($DownloadLabel)) {
        $DownloadLabel = 'NoLabel'
    }
    
    # Normalize torrent hash
    if (-not [string]::IsNullOrWhiteSpace($TorrentHash)) {
        $TorrentHash = $TorrentHash.ToUpper().Trim()
    }
    
    # Generate job ID (deterministic based on path + hash)
    $idSource = "$DownloadPath|$TorrentHash"
    $jobId = Get-SAHash -InputString $idSource -Length 16
    
    # Ensure queue directories exist
    $pendingDir = Join-Path -Path $QueueRoot -ChildPath 'pending'
    $runningDir = Join-Path -Path $QueueRoot -ChildPath 'running'
    $completedDir = Join-Path -Path $QueueRoot -ChildPath 'completed'
    $failedDir = Join-Path -Path $QueueRoot -ChildPath 'failed'
    
    New-SADirectory -Path $pendingDir
    New-SADirectory -Path $runningDir
    New-SADirectory -Path $completedDir
    New-SADirectory -Path $failedDir
    
    # Check for duplicate (in any state)
    $jobFileName = "$jobId.json"
    $existingStates = @($pendingDir, $runningDir, $completedDir, $failedDir)
    
    foreach ($stateDir in $existingStates) {
        $existingPath = Join-Path -Path $stateDir -ChildPath $jobFileName
        if (Test-Path -LiteralPath $existingPath) {
            if ($Force) {
                # Remove existing job to allow re-run
                Remove-Item -LiteralPath $existingPath -Force -ErrorAction SilentlyContinue
                Write-SAVerbose -Label "Queue" -Text "Removed existing job (ID: $jobId)"
            } else {
                Write-SAVerbose -Label "Queue" -Text "Job already exists (ID: $jobId)"
                Write-SAProgress -Label "Queue" -Text "Job already queued, skipping"
                return $null
            }
        }
    }
    
    # Create job object
    $job = @{
        id        = $jobId
        version   = 1
        createdAt = Get-SATimestamp
        updatedAt = Get-SATimestamp
        state     = 'pending'
        attempts  = 0
        lastError = $null
        
        input = @{
            downloadPath  = $DownloadPath
            downloadLabel = $DownloadLabel
            torrentHash   = $TorrentHash
            noCleanup     = [bool]$NoCleanup
            noMail        = [bool]$NoMail
        }
        
        result = $null
    }
    
    # Write job file atomically (prevents corruption on crash/power loss)
    $jobPath = Join-Path -Path $pendingDir -ChildPath $jobFileName
    $jobJson = $job | ConvertTo-Json -Depth 10
    Write-SAFileAtomicUtf8NoBom -Path $jobPath -Content $jobJson
    
    Write-SAVerbose -Label "Queue" -Text "Job ID: $jobId"
    
    return $job
}

function Get-SAJob {
    <#
    .SYNOPSIS
        Gets a job by ID.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER JobId
        Job ID to retrieve.
    .OUTPUTS
        Job object or $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,
        
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )
    
    $jobFileName = "$JobId.json"
    $states = @('pending', 'running', 'completed', 'failed')
    
    foreach ($state in $states) {
        $jobPath = Join-Path -Path $QueueRoot -ChildPath $state | Join-Path -ChildPath $jobFileName
        if (Test-Path -LiteralPath $jobPath) {
            return Read-SAJobFile -Path $jobPath
        }
    }
    
    return $null
}

function Get-SAJobs {
    <#
    .SYNOPSIS
        Gets jobs by state or all jobs.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER State
        Filter by state: pending, running, completed, failed, or all.
    .PARAMETER Limit
        Maximum number of jobs to return (default: 100).
    .OUTPUTS
        Array of job objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,
        
        [Parameter()]
        [ValidateSet('pending', 'running', 'completed', 'failed', 'all')]
        [string]$State = 'all',
        
        [Parameter()]
        [int]$Limit = 100
    )
    
    $jobs = [System.Collections.Generic.List[hashtable]]::new()
    
    $states = if ($State -eq 'all') {
        @('pending', 'running', 'completed', 'failed')
    } else {
        @($State)
    }
    
    foreach ($s in $states) {
        $stateDir = Join-Path -Path $QueueRoot -ChildPath $s
        if (Test-Path -LiteralPath $stateDir) {
            $files = Get-ChildItem -LiteralPath $stateDir -Filter '*.json' | Sort-Object -Property LastWriteTime -Descending | Select-Object -First $Limit
            foreach ($file in $files) {
                $job = Read-SAJobFile -Path $file.FullName
                if ($null -ne $job) {
                    $jobs.Add($job)
                }
                
                if ($jobs.Count -ge $Limit) {
                    break
                }
            }
        }
        
        if ($jobs.Count -ge $Limit) {
            break
        }
    }
    
    return $jobs.ToArray()
}

function Remove-SAJob {
    <#
    .SYNOPSIS
        Removes a job from the queue.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER JobId
        Job ID to remove.
    .OUTPUTS
        $true if removed, $false if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,
        
        [Parameter(Mandatory = $true)]
        [string]$JobId
    )
    
    $jobFileName = "$JobId.json"
    $states = @('pending', 'running', 'completed', 'failed')
    
    foreach ($state in $states) {
        $jobPath = Join-Path -Path $QueueRoot -ChildPath $state | Join-Path -ChildPath $jobFileName
        if (Test-Path -LiteralPath $jobPath) {
            Remove-Item -LiteralPath $jobPath -Force
            Write-SAProgress -Label "Queue" -Text "Job removed (ID: $JobId)"
            return $true
        }
    }
    
    return $false
}

function Restore-SAOrphanedJobs {
    <#
    .SYNOPSIS
        Restores orphaned running jobs back to pending.
    .DESCRIPTION
        When a worker acquires the lock, any jobs in "running" state are orphaned
        (from crashes/reboots) since the previous worker is no longer running.
        This function moves them back to pending for reprocessing.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .OUTPUTS
        Number of jobs recovered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot
    )
    
    $runningPath = Join-Path -Path $QueueRoot -ChildPath 'running'
    $recoveredCount = 0
    
    if (-not (Test-Path -LiteralPath $runningPath)) {
        return 0
    }
    
    $runningJobs = Get-ChildItem -LiteralPath $runningPath -Filter '*.json' -ErrorAction SilentlyContinue
    
    foreach ($jobFile in $runningJobs) {
        try {
            $job = Get-Content -LiteralPath $jobFile.FullName -Raw | ConvertFrom-Json | ConvertTo-SAHashtable
            
            # Move back to pending
            Move-SAJobState -QueueRoot $QueueRoot -JobId $job.id -FromState 'running' -ToState 'pending'
            
            # Update job state
            $job.state = 'pending'
            $job.updatedAt = Get-SATimestamp
            $job.lastError = 'Recovered from orphaned running state (system restart)'
            Update-SAJobFile -QueueRoot $QueueRoot -Job $job
            
            $recoveredCount++
            Write-SAVerbose -Label "Queue" -Text "Recovered orphaned job: $($job.id)"
        } catch {
            Write-Warning "Failed to recover job $($jobFile.Name): $_"
        }
    }
    
    return $recoveredCount
}

function Start-SAWorker {
    <#
    .SYNOPSIS
        Starts the job worker to process pending jobs.
    .DESCRIPTION
        Acquires the global lock, then processes pending jobs one at a time.
        Jobs are moved from pending -> running -> completed/failed.
        Orphaned running jobs (from crashes) are automatically recovered.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER Config
        Configuration hashtable.
    .PARAMETER MaxJobs
        Maximum jobs to process before exiting (default: 0 = unlimited).
    .PARAMETER ProcessJob
        Script block to process each job. Receives: $Context, $Job. Should return $true on success.
    .EXAMPLE
        Start-SAWorker -QueueRoot "C:\Queue" -Config $config -ProcessJob { param($ctx, $job) ... }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        
        [Parameter()]
        [int]$MaxJobs = 0,

        [Parameter()]
        [switch]$Wait,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ProcessJob
    )
    
    # Try to acquire lock
    $lock = Get-SAGlobalLock -QueueRoot $QueueRoot -StaleMinutes $Config.processing.staleLockMinutes -Wait:$Wait
    
    if ($null -eq $lock) {
        Write-SAProgress -Label "Queue" -Text "Could not acquire lock, exiting"
        return
    }
    
    $jobsProcessed = 0
    
    try {
        # Recovery: Check for orphaned running jobs and move back to pending
        # Since we just acquired the lock, any "running" jobs are orphaned (from crashes/reboots)
        $recoveredCount = Restore-SAOrphanedJobs -QueueRoot $QueueRoot
        if ($recoveredCount -gt 0) {
            $jobWord = Get-SAPluralForm -Count $recoveredCount -Singular 'job'
            Write-SAProgress -Label "Queue" -Text "Recovered $recoveredCount orphaned $jobWord"
        }
        
        while ($true) {
            # Get next pending job
            $pendingJob = Get-SANextPendingJob -QueueRoot $QueueRoot
            
            if ($null -eq $pendingJob) {
                if ($jobsProcessed -eq 0) {
                    Write-SAProgress -Label "Queue" -Text "No pending jobs"
                }
                break
            }
            
            # Move to running (update job content BEFORE moving for atomicity —
            # crash between move and write would lose attempt counter)
            $pendingJob.attempts = $pendingJob.attempts + 1
            $pendingJob.startedAt = Get-SATimestamp
            $pendingJob.updatedAt = Get-SATimestamp
            Update-SAJobFile -QueueRoot $QueueRoot -Job $pendingJob
            Move-SAJobState -QueueRoot $QueueRoot -JobId $pendingJob.id -FromState 'pending' -ToState 'running'
            $pendingJob.state = 'running'
            
            # Console header with short name
            $jobName = Split-Path $pendingJob.input.downloadPath -Leaf
            Write-SAPhaseHeader -Title "Job: $jobName"
            Write-SAProgress -Label "Path" -Text $pendingJob.input.downloadPath
            Write-SAProgress -Label "Label" -Text $pendingJob.input.downloadLabel
            
            # Create context
            $context = New-SAContext -Config $Config
            
            try {
                # Reset module state to prevent memory leaks from previous jobs
                Reset-SAJobState
                
                # Initialize context with job (this initializes output system with job metadata)
                Initialize-SAContext -Context $context -Job $pendingJob
                
                # Note: Start time is captured by Initialize-SAOutputSystem in TSJobMetadata
                # and included in file log header automatically
                
                # Hash logged to Verbose for troubleshooting, but not needed in email
                if (-not [string]::IsNullOrWhiteSpace($pendingJob.input.torrentHash)) {
                    Write-SAVerbose -Label "Job" -Text "Torrent hash: $($pendingJob.input.torrentHash)"
                }
                
                # Run the job processor
                $result = & $ProcessJob $context $pendingJob
                
                # Explicitly check for boolean true (not just truthy)
                # Script blocks can return multiple values, take the last one
                $success = $false
                if ($result -is [array]) {
                    $lastResult = $result[-1]
                    if ($lastResult -eq $true) {
                        $success = $true
                    }
                } elseif ($result -eq $true) {
                    $success = $true
                }
                
                if ($success) {
                    # Move to completed
                    $pendingJob.state = 'completed'
                    $pendingJob.updatedAt = Get-SATimestamp
                    $duration = Get-SAContextDuration -Context $context
                    $pendingJob.result = @{
                        exitReason  = "$($pendingJob.input.downloadLabel) - $(Split-Path $pendingJob.input.downloadPath -Leaf)"
                        logFile     = Get-SAContextLogPath -Context $context
                        duration    = $duration.ToString('mm\:ss')
                        completedAt = Get-SATimestamp
                    }

                    Move-SAJobState -QueueRoot $QueueRoot -JobId $pendingJob.id -FromState 'running' -ToState 'completed'
                    Update-SAJobFile -QueueRoot $QueueRoot -Job $pendingJob
                    
                    Write-SAOutcome -Level Success -Label "Job" -Text "Completed successfully"
                } else {
                    throw "Job processor returned false"
                }
                
            } catch {
                # Move to failed
                $pendingJob.state = 'failed'
                $pendingJob.updatedAt = Get-SATimestamp
                $pendingJob.lastError = $_.Exception.Message
                $pendingJob.result = @{
                    completedAt = Get-SATimestamp
                }

                Move-SAJobState -QueueRoot $QueueRoot -JobId $pendingJob.id -FromState 'running' -ToState 'failed'
                Update-SAJobFile -QueueRoot $QueueRoot -Job $pendingJob
                
                Write-SAOutcome -Level Error -Label "Job" -Text "Failed: $($_.Exception.Message)"
            } finally {
                # Always save log file, even on error (per OUTPUT-STYLE-GUIDE: "Create a log file for every run")
                # Note: On success, JobProcessor already saved the log. This is a safety net for failures.
                try {
                    $logPath = Get-SAContextLogPath -Context $context
                    if (-not [string]::IsNullOrWhiteSpace($logPath)) {
                        $savedPath = Save-SAFileLog -Path $logPath
                        # Only show log path if we actually saved it (not already saved by JobProcessor)
                        if (-not [string]::IsNullOrWhiteSpace($savedPath)) {
                            Write-SAProgress -Label "Log" -Text $logPath -ConsoleOnly
                        }
                    }
                } catch {
                    Write-SAVerbose -Label "FileLog" -Text "Failed to save: $($_.Exception.Message)"
                }
            }
            
            $jobsProcessed++
            
            # Check max jobs limit
            if ($MaxJobs -gt 0 -and $jobsProcessed -ge $MaxJobs) {
                Write-SAProgress -Label "Worker" -Text "Reached max jobs limit ($MaxJobs)"
                break
            }
        }
        
    } finally {
        Unlock-SAGlobalLock -Lock $lock
        $jobWord = Get-SAPluralForm -Count $jobsProcessed -Singular 'job'
        # C3 fix: Worker summary is verbose-only (per OUTPUT-STYLE-GUIDE "Silence Is Golden")
        Write-SAVerbose -Text "Worker: Processed $jobsProcessed $jobWord"
    }
}

# --- Private helper functions ---

function Read-SAJobFile {
    <#
    .SYNOPSIS
        Reads and parses a job file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-SAVerbose -Label "Queue" -Text "Job file not found: $Path"
            return $null
        }
        
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        
        if ([string]::IsNullOrWhiteSpace($json)) {
            Write-SAVerbose -Label "Queue" -Text "Job file is empty: $Path"
            return $null
        }
        
        $data = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        
        if ($null -eq $data) {
            Write-SAVerbose -Label "Queue" -Text "Failed to parse job file: $Path"
            return $null
        }
        
        # Convert to hashtable for easier manipulation
        return ConvertTo-SAHashtable -InputObject $data
    } catch {
        Write-SAVerbose -Label "Queue" -Text "Failed to read job file: $Path"
        return $null
    }
}

function Update-SAJobFile {
    <#
    .SYNOPSIS
        Updates a job file with new data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Job
    )
    
    $jobFileName = "$($Job.id).json"
    $jobPath = Join-Path -Path $QueueRoot -ChildPath $Job.state | Join-Path -ChildPath $jobFileName
    
    # Write atomically to prevent corruption on crash/power loss
    $jobJson = $Job | ConvertTo-Json -Depth 10
    Write-SAFileAtomicUtf8NoBom -Path $jobPath -Content $jobJson
}

function Move-SAJobState {
    <#
    .SYNOPSIS
        Moves a job file between state directories.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,
        
        [Parameter(Mandatory = $true)]
        [string]$JobId,
        
        [Parameter(Mandatory = $true)]
        [string]$FromState,
        
        [Parameter(Mandatory = $true)]
        [string]$ToState
    )
    
    $jobFileName = "$JobId.json"
    $fromPath = Join-Path -Path $QueueRoot -ChildPath $FromState | Join-Path -ChildPath $jobFileName
    $toPath = Join-Path -Path $QueueRoot -ChildPath $ToState | Join-Path -ChildPath $jobFileName
    
    if (Test-Path -LiteralPath $fromPath) {
        # Ensure destination directory exists
        $toDir = Join-Path -Path $QueueRoot -ChildPath $ToState
        New-SADirectory -Path $toDir
        
        Move-Item -LiteralPath $fromPath -Destination $toPath -Force
    }
}

function Get-SANextPendingJob {
    <#
    .SYNOPSIS
        Gets the next pending job (FIFO order by creation time).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot
    )
    
    $pendingDir = Join-Path -Path $QueueRoot -ChildPath 'pending'
    
    if (-not (Test-Path -LiteralPath $pendingDir)) {
        return $null
    }
    
    # Get oldest job file
    $files = Get-ChildItem -LiteralPath $pendingDir -Filter '*.json' | Sort-Object CreationTime, Name
    
    if ($files.Count -eq 0) {
        return $null
    }
    
    return Read-SAJobFile -Path $files[0].FullName
}

function Update-SAJobProgress {
    <#
    .SYNOPSIS
        Updates the progress field of a running job.
    .DESCRIPTION
        Writes current phase and activity to the running job's JSON file
        so that -Status can display what the worker is doing.
        Silently does nothing if the job file is not found (non-critical).
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER JobId
        Job ID to update.
    .PARAMETER Phase
        Current processing phase (Staging, Subtitles, Import, Finalize).
    .PARAMETER Activity
        Current activity description.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,

        [Parameter(Mandatory = $true)]
        [string]$JobId,

        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter()]
        [string]$Activity = ''
    )

    $jobFileName = "$JobId.json"
    $jobPath = Join-Path -Path $QueueRoot -ChildPath 'running' | Join-Path -ChildPath $jobFileName

    if (-not (Test-Path -LiteralPath $jobPath)) {
        return
    }

    try {
        $job = Read-SAJobFile -Path $jobPath
        if ($null -eq $job) { return }

        $job.progress = @{
            phase     = $Phase
            activity  = $Activity
            updatedAt = Get-SATimestamp
        }

        $jobJson = $job | ConvertTo-Json -Depth 10
        Write-SAFileAtomicUtf8NoBom -Path $jobPath -Content $jobJson
    } catch {
        # Non-critical - don't let progress updates break processing
        Write-SAVerbose -Label "Queue" -Text "Progress update failed: $($_.Exception.Message)"
    }
}