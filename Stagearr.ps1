#Requires -Version 5.1
<#
.SYNOPSIS
    Stagearr vNext - qBittorrent Post-Processing Automation
.DESCRIPTION
    Handles post-processing of completed torrent downloads:
    - Unrar archives to staging
    - MP4→MKV remux
    - Subtitle extraction/stripping from MKV
    - OpenSubtitles download
    - Subtitle cleanup via SubtitleEdit
    - Import to Radarr/Sonarr/Medusa
    - Email notifications
    
    Designed for qBittorrent's "Run external program on torrent completion" hook.
    Uses a file-backed queue for reliability across reboots.
    
.PARAMETER DownloadPath
    Path to the downloaded torrent (file or folder).
    
.PARAMETER DownloadLabel
    Torrent label/category (e.g., TV, Movie).
    Empty becomes "NoLabel". "NoProcess" skips processing entirely.
    
.PARAMETER TorrentHash
    Torrent hash (used for Radarr/Sonarr import matching).
    
.PARAMETER NoCleanup
    Skip staging folder cleanup after processing.
    
.PARAMETER NoMail
    Skip email notification for this job.
    
.PARAMETER Force
    Force re-run of a job even if it already exists (completed or failed).
    
.PARAMETER Wait
    Wait for the lock if another instance is currently processing.
    Without this flag, the worker exits immediately if the lock is held
    (the job is still queued and will be picked up by the active worker).
    Useful for manual runs when you want to see console output.

.PARAMETER Status
    Show queue status and exit.

.PARAMETER SyncConfig
    Compare config.toml against config-sample.toml and report
    missing or extra settings.

.PARAMETER Setup
    Run interactive setup wizard to create or edit config.toml.

.PARAMETER ConfigPath
    Path to config.toml (default: same directory as script).

.EXAMPLE
    # qBittorrent completion hook:
    Stagearr.ps1 -DownloadPath "%F" -DownloadLabel "%L" -TorrentHash "%I"
    
.EXAMPLE
    # Manual processing:
    Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie"
    
.EXAMPLE
    # Check queue status:
    Stagearr.ps1 -Status

.EXAMPLE
    # Check for missing/extra settings:
    Stagearr.ps1 -SyncConfig

.EXAMPLE
    # Interactive setup wizard:
    Stagearr.ps1 -Setup

.EXAMPLE
    # Re-run a previously completed/failed job:
    Stagearr.ps1 -DownloadPath "C:\Downloads\Movie.2024" -DownloadLabel "Movie" -Force

.NOTES
    Version: 2.0.1
    Requires: PowerShell 5.1 or 7.x
    External Tools: WinRAR, MKVToolNix, SubtitleEdit
#>

[CmdletBinding(DefaultParameterSetName = 'Enqueue')]
param(
    [Parameter(ParameterSetName = 'Enqueue', Position = 0)]
    [string]$DownloadPath,
    
    [Parameter(ParameterSetName = 'Enqueue')]
    [string]$DownloadLabel = '',
    
    [Parameter(ParameterSetName = 'Enqueue')]
    [string]$TorrentHash = '',
    
    [Parameter(ParameterSetName = 'Enqueue')]
    [switch]$NoCleanup,
    
    [Parameter(ParameterSetName = 'Enqueue')]
    [Alias('NoMail')]
    [switch]$SkipEmail,
    
    [Parameter(ParameterSetName = 'Enqueue')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Enqueue')]
    [switch]$Wait,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status,
    
    [Parameter(ParameterSetName = 'SyncConfig')]
    [switch]$SyncConfig,

    [Parameter(ParameterSetName = 'Setup')]
    [switch]$Setup,

    [Parameter()]
    [string]$ConfigPath
)

# Determine script root and module path
$ScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Import the core module
$ModulePath = Join-Path -Path $ScriptRoot -ChildPath 'Modules\Stagearr.Core\Stagearr.Core.psd1'
if (-not (Test-Path -LiteralPath $ModulePath)) {
    Write-Host "ERROR: Module not found at: $ModulePath" -ForegroundColor Red
    exit 1
}

try {
    # Suppress module loading verbose messages (redirect verbose stream to null)
    $null = Import-Module $ModulePath -Force -DisableNameChecking -ErrorAction Stop -Verbose:$false 4>&1
} catch {
    Write-Host "ERROR: Failed to import module: $_" -ForegroundColor Red
    exit 1
}

$StagearrVersion = (Get-Module -Name 'Stagearr.Core').Version.ToString()

# Determine config path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path -Path $ScriptRoot -ChildPath 'config.toml'
}

# Handle SyncConfig mode BEFORE loading config (config may be invalid)
if ($PSCmdlet.ParameterSetName -eq 'SyncConfig') {
    # Initialize console renderer with defaults (no config loaded yet)
    Initialize-SAConsoleRenderer -UseColors $true
    
    # Display banner
    Write-SABanner -Title "Stagearr" -Version $StagearrVersion
    
    Write-SAPhaseHeader -Title "Configuration Sync"
    
    # Check if config.toml exists
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-SAOutcome -Level Error -Label "Config" -Text "Not found: $ConfigPath"
        Write-SAProgress -Label "Hint" -Text "Run: .\Stagearr.ps1 -Setup"
        exit 1
    }

    $samplePath = Join-Path $ScriptRoot 'config-sample.toml'
    if (-not (Test-Path -LiteralPath $samplePath)) {
        Write-SAOutcome -Level Error -Label "Sample" -Text "Not found: $samplePath"
        exit 1
    }

    # Run sync report
    $result = Sync-SAConfig -ConfigPath $ConfigPath -SamplePath $samplePath

    if ($result.MissingCount -eq 0 -and $result.ExtraCount -eq 0) {
        Write-SAOutcome -Level Success -Label "Status" -Text "Configuration is up to date"
    }
    else {
        Write-SAProgress -Label "Status" -Text $result.Message
    }
    
    exit 0
}

# Handle Setup mode BEFORE loading config
if ($PSCmdlet.ParameterSetName -eq 'Setup') {
    Initialize-SAConsoleRenderer -UseColors $true
    Write-SABanner -Title "Stagearr" -Version $StagearrVersion
    Write-SAPhaseHeader -Title "Setup Wizard"

    $samplePath = Join-Path $ScriptRoot 'config-sample.toml'
    if (-not (Test-Path -LiteralPath $samplePath)) {
        Write-SAOutcome -Level Error -Label "Sample" -Text "Not found: $samplePath"
        exit 1
    }

    Invoke-SASetup -ConfigPath $ConfigPath -SamplePath $samplePath
    exit 0
}

# Load configuration (for all other modes)
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "ERROR: Configuration file not found: $ConfigPath" -ForegroundColor Red
    Write-Host "Run '.\Stagearr.ps1 -Setup' to create one, or copy config-sample.toml to config.toml" -ForegroundColor Yellow
    exit 1
}
try {
    $Config = Read-SAConfig -Path $ConfigPath
} catch {
    Write-Host "ERROR: Failed to load configuration: $_" -ForegroundColor Red
    exit 1
}

# Store script root in config for reference
$Config['_scriptRoot'] = $ScriptRoot
$Config['_configPath'] = $ConfigPath

# Initialize console renderer
Initialize-SAConsoleRenderer -UseColors $Config.logging.consoleColors

# Display banner
Write-SABanner -Title "Stagearr" -Version $StagearrVersion

# Handle different modes
switch ($PSCmdlet.ParameterSetName) {
    'Status' {
        # Show queue status
        Write-SAPhaseHeader -Title "Queue Status"

        # Use @() to ensure arrays even with single item
        $pending = @(Get-SAJobs -QueueRoot $Config.paths.queueRoot -State 'pending')
        $running = @(Get-SAJobs -QueueRoot $Config.paths.queueRoot -State 'running')
        $completed = @(Get-SAJobs -QueueRoot $Config.paths.queueRoot -State 'completed' -Limit 10)
        $failed = @(Get-SAJobs -QueueRoot $Config.paths.queueRoot -State 'failed' -Limit 10)

        Write-SAKeyValue -Key "Pending" -Value $pending.Count
        Write-SAKeyValue -Key "Running" -Value $running.Count
        Write-SAKeyValue -Key "Completed" -Value "$($completed.Count) (last 10)"
        Write-SAKeyValue -Key "Failed" -Value "$($failed.Count) (last 10)"

        # Show lock status (compact)
        $lockHeld = Test-SAGlobalLock -QueueRoot $Config.paths.queueRoot
        if ($lockHeld) {
            $lockInfo = Get-SAGlobalLockInfo -QueueRoot $Config.paths.queueRoot
            if ($lockInfo) {
                $lockSince = $lockInfo.startedAt.ToString('HH:mm:ss')
                Write-SAKeyValue -Key "Lock" -Value "Held (PID $($lockInfo.pid), since $lockSince)"
            } else {
                Write-SAKeyValue -Key "Lock" -Value "Held"
            }
        } else {
            Write-SAKeyValue -Key "Lock" -Value "Available"
        }

        # Show running jobs with details
        if ($running.Count -gt 0) {
            Write-SAPhaseHeader -Title "Running"
            foreach ($job in $running) {
                $name = Split-Path -Path $job.input.downloadPath -Leaf
                Write-SAKeyValue -Key "Title" -Value $name
                Write-SAKeyValue -Key "Label" -Value $job.input.downloadLabel

                # Calculate elapsed time
                $elapsedTimestamp = if ($job.startedAt) { $job.startedAt } else { $job.updatedAt }
                if ($elapsedTimestamp) {
                    try {
                        $startTime = [datetime]::Parse(
                            $elapsedTimestamp,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                        $elapsed = (Get-Date) - $startTime.ToLocalTime()
                        if ($elapsed.TotalHours -ge 1) {
                            $elapsedStr = '{0}h {1}m' -f [int]$elapsed.TotalHours, $elapsed.Minutes
                        } elseif ($elapsed.TotalMinutes -ge 1) {
                            $elapsedStr = '{0}m {1}s' -f [int]$elapsed.TotalMinutes, $elapsed.Seconds
                        } else {
                            $elapsedStr = '{0}s' -f [int]$elapsed.TotalSeconds
                        }
                        Write-SAKeyValue -Key "Elapsed" -Value $elapsedStr
                    } catch {
                        # Skip elapsed if timestamp can't be parsed
                    }
                }

                # Show progress if available
                if ($job.progress) {
                    if ($job.progress.phase) {
                        Write-SAKeyValue -Key "Phase" -Value $job.progress.phase
                    }
                    if ($job.progress.activity) {
                        Write-SAKeyValue -Key "Activity" -Value $job.progress.activity
                    }
                }
            }
        }

        # Show pending jobs
        if ($pending.Count -gt 0) {
            Write-SAPhaseHeader -Title "Pending"
            foreach ($job in $pending) {
                $name = Split-Path -Path $job.input.downloadPath -Leaf
                Write-SAKeyValue -Key $job.id.Substring(0, 8) -Value "$($job.input.downloadLabel): $name"
            }
        }

        # Show completed jobs with result, duration, and time
        if ($completed.Count -gt 0) {
            Write-SAPhaseHeader -Title "Completed (Recent)"
            foreach ($job in $completed) {
                $name = Split-Path -Path $job.input.downloadPath -Leaf
                if ($name.Length -gt 60) { $name = $name.Substring(0, 57) + '...' }
                $label = $job.input.downloadLabel

                # Get duration and completion time from result
                $duration = ''
                $finishTime = ''
                if ($job.result) {
                    if ($job.result.duration) {
                        $duration = $job.result.duration
                    }
                    if ($job.result.completedAt) {
                        try {
                            $completedDt = [datetime]::Parse(
                                $job.result.completedAt,
                                [System.Globalization.CultureInfo]::InvariantCulture,
                                [System.Globalization.DateTimeStyles]::RoundtripKind
                            )
                            $finishTime = $completedDt.ToLocalTime().ToString('HH:mm')
                        } catch {
                            $finishTime = ''
                        }
                    }
                }

                # Fall back to updatedAt if no completedAt
                if ([string]::IsNullOrWhiteSpace($finishTime) -and $job.updatedAt) {
                    try {
                        $updatedDt = [datetime]::Parse(
                            $job.updatedAt,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                        $finishTime = $updatedDt.ToLocalTime().ToString('HH:mm')
                    } catch { }
                }

                $parts = @($label)
                if ($duration) { $parts += $duration }
                if ($finishTime) { $parts += $finishTime }
                $detail = $parts -join '  '

                Write-SAOutcome -Level Success -Text "$name  $detail"
            }
        }

        # Show failed jobs
        if ($failed.Count -gt 0) {
            Write-SAPhaseHeader -Title "Failed (Recent)"
            foreach ($job in $failed) {
                $name = Split-Path -Path $job.input.downloadPath -Leaf
                if ($name.Length -gt 60) { $name = $name.Substring(0, 57) + '...' }
                $label = $job.input.downloadLabel

                $finishTime = ''
                if ($job.result -and $job.result.completedAt) {
                    try {
                        $completedDt = [datetime]::Parse(
                            $job.result.completedAt,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                        $finishTime = $completedDt.ToLocalTime().ToString('HH:mm')
                    } catch { }
                }
                if ([string]::IsNullOrWhiteSpace($finishTime) -and $job.updatedAt) {
                    try {
                        $updatedDt = [datetime]::Parse(
                            $job.updatedAt,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                        $finishTime = $updatedDt.ToLocalTime().ToString('HH:mm')
                    } catch { }
                }

                $parts = @($label)
                if ($finishTime) { $parts += $finishTime }
                $detail = $parts -join '  '

                Write-SAOutcome -Level Error -Text "$name  $detail"
                if ($job.lastError) {
                    Write-SAProgress -Label "Error" -Text $job.lastError -Indent 2
                }
            }
        }

        exit 0
    }
    
    'Enqueue' {
        # Enqueue a new job
        
        # Validate download path
        if ([string]::IsNullOrWhiteSpace($DownloadPath)) {
            Write-SAOutcome -Level Error -Text "DownloadPath is required"
            Write-Host ""
            Write-Host "Usage: Stagearr.ps1 -DownloadPath <path> [-DownloadLabel <label>] [-TorrentHash <hash>]"
            Write-Host ""
            exit 1
        }
        
        # Check if path exists
        if (-not (Test-Path -LiteralPath $DownloadPath)) {
            Write-SAOutcome -Level Error -Label "Path" -Text "Not found: $DownloadPath"
            exit 1
        }
        
        # Normalize label
        if ([string]::IsNullOrWhiteSpace($DownloadLabel)) {
            $DownloadLabel = 'NoLabel'
        }
        
        # Check for skip label
        if ($DownloadLabel -eq $Config.labels.skip) {
            Write-SAProgress -Label "Skip" -Text "Label is '$($Config.labels.skip)', not processing"
            exit 0
        }
        
        # Check if label should skip email
        if ($DownloadLabel -eq 'NoMail') {
            $SkipEmail = $true
        }
        
        if ($Wait) {
            # Defer job creation until after lock acquisition to prevent
            # the background worker from stealing it during the wait period
            $jobParams = @{
                QueueRoot     = $Config.paths.queueRoot
                DownloadPath  = $DownloadPath
                DownloadLabel = $DownloadLabel
                TorrentHash   = $TorrentHash
                NoCleanup     = $NoCleanup
                NoMail        = $SkipEmail
                Force         = $Force
            }

            Start-SAWorker -QueueRoot $Config.paths.queueRoot -Config $Config -Wait `
                -Verbose:($VerbosePreference -eq 'Continue') `
                -DeferredJobParams $jobParams `
                -ProcessJob {
                    param($Context, $Job)
                    Invoke-SAJobProcessing -Context $Context -Job $Job
                }
        } else {
            # Add job immediately so background worker picks it up
            $job = Add-SAJob -QueueRoot $Config.paths.queueRoot `
                -DownloadPath $DownloadPath `
                -DownloadLabel $DownloadLabel `
                -TorrentHash $TorrentHash `
                -NoCleanup:$NoCleanup `
                -NoMail:$SkipEmail `
                -Force:$Force

            if ($null -eq $job) {
                Write-SAProgress -Label "Queue" -Text "Job already exists or was skipped"
                Write-SAProgress -Label "Hint" -Text "Use -Force to re-run"
                exit 0
            }

            Start-SAWorker -QueueRoot $Config.paths.queueRoot -Config $Config `
                -Verbose:($VerbosePreference -eq 'Continue') `
                -ProcessJob {
                    param($Context, $Job)
                    Invoke-SAJobProcessing -Context $Context -Job $Job
                }
        }
        
        exit 0
    }
}