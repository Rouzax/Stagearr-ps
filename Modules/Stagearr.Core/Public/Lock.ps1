#Requires -Version 5.1
<#
.SYNOPSIS
    Global lock management for Stagearr
.DESCRIPTION
    File-based global lock to ensure only one worker processes jobs at a time.
    Supports stale lock recovery (dead PID, PID reuse detection, timeout).
    
    PID Reuse Protection: Lock files include process start time to distinguish
    between the original lock holder and a new process that was assigned the
    same PID after the original process died.
#>

function Get-SAGlobalLock {
    <#
    .SYNOPSIS
        Acquires the global worker lock.
    .DESCRIPTION
        Creates a lock file with PID and timestamp. Handles stale lock recovery.
        Returns a lock object that must be released with Unlock-SAGlobalLock.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER StaleMinutes
        Minutes after which a lock is considered stale (default: 15).
    .PARAMETER Wait
        Wait for lock to become available (default: false, fail immediately).
    .PARAMETER WaitTimeoutSeconds
        Maximum seconds to wait for lock (default: 60).
    .OUTPUTS
        Lock object if acquired, $null if failed.
    .EXAMPLE
        $lock = Get-SAGlobalLock -QueueRoot "C:\Stagearr\Queue"
        try {
            # Do work
        } finally {
            Unlock-SAGlobalLock -Lock $lock
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,
        
        [Parameter()]
        [int]$StaleMinutes = 15,
        
        [Parameter()]
        [switch]$Wait,
        
        [Parameter()]
        [int]$WaitTimeoutSeconds = 60
    )
    
    # Ensure queue root exists
    New-SADirectory -Path $QueueRoot
    
    $lockPath = Join-Path -Path $QueueRoot -ChildPath '.lock'
    $startTime = Get-Date
    $acquired = $false
    
    do {
        # Check for existing lock
        if (Test-Path -LiteralPath $lockPath) {
            $existingLock = Get-SALockInfo -LockPath $lockPath
            
            if ($null -ne $existingLock) {
                # Check if lock is stale
                $isStale = Test-SALockStale -LockInfo $existingLock -StaleMinutes $StaleMinutes -QueueRoot $QueueRoot
                
                if ($isStale) {
                    # Determine if this was a remote or local lock for better messaging
                    $lockHostname = $existingLock.hostname
                    $isRemote = $lockHostname -and ($lockHostname -ne $env:COMPUTERNAME)
                    
                    if ($isRemote) {
                        Write-SAOutcome -Level Warning -Text "Recovering stale lock (host: $lockHostname, PID: $($existingLock.pid), started: $($existingLock.startedAt))"
                        $staleReason = "Remote lock timeout (host: $lockHostname)"
                    } else {
                        Write-SAOutcome -Level Warning -Text "Recovering stale lock (PID: $($existingLock.pid), started: $($existingLock.startedAt))"
                        $staleReason = "Process not alive or timeout"
                    }
                    
                    # Write to diagnostic log before removing
                    Write-SALockDiagnostic -QueueRoot $QueueRoot -Action 'remove_stale' -LockInfo $existingLock -Reason $staleReason
                    
                    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                } else {
                    # Lock is held by active process
                    $lockHostname = $existingLock.hostname
                    $isRemote = $lockHostname -and ($lockHostname -ne $env:COMPUTERNAME)
                    
                    if (-not $Wait) {
                        if ($isRemote) {
                            Write-SAProgress -Label "Lock" -Text "Already held by $lockHostname (PID $($existingLock.pid))"
                        } else {
                            Write-SAProgress -Label "Lock" -Text "Already held by PID $($existingLock.pid)"
                        }
                        return $null
                    }
                    
                    # Check timeout
                    $elapsed = (Get-Date) - $startTime
                    if ($elapsed.TotalSeconds -ge $WaitTimeoutSeconds) {
                        Write-SAOutcome -Level Warning -Text "Lock wait timeout after $WaitTimeoutSeconds seconds"
                        return $null
                    }
                    
                    # Wait and retry
                    Start-Sleep -Seconds 2
                    continue
                }
            } else {
                # CRITICAL: Cannot parse lock file - be CONSERVATIVE and treat as held
                # This prevents race conditions where we accidentally remove a valid lock
                # that's still being written or has temporary read issues
                Write-SAVerbose -Label "Lock" -Text "Lock file unreadable - assuming held (conservative)"
                
                # Check if lock file is extremely old (based on file modification time)
                # This handles truly corrupt/orphaned lock files while remaining safe
                try {
                    $lockFileInfo = Get-Item -LiteralPath $lockPath -ErrorAction Stop
                    $fileAge = (Get-Date) - $lockFileInfo.LastWriteTime
                    
                    if ($fileAge.TotalMinutes -ge $StaleMinutes) {
                        # Lock file is very old and unreadable - likely truly corrupt
                        Write-SAOutcome -Level Warning -Text "Removing unreadable lock file (age: $([int]$fileAge.TotalMinutes) minutes)"
                        Write-SALockDiagnostic -QueueRoot $QueueRoot -Action 'remove_corrupt' -Reason "Unreadable lock file, age: $([int]$fileAge.TotalMinutes) minutes"
                        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                    } else {
                        # Lock file is recent but unreadable - be safe and wait
                        if (-not $Wait) {
                            Write-SAProgress -Label "Lock" -Text "Lock file exists but unreadable - assuming held"
                            return $null
                        }
                        
                        # Check timeout
                        $elapsed = (Get-Date) - $startTime
                        if ($elapsed.TotalSeconds -ge $WaitTimeoutSeconds) {
                            Write-SAOutcome -Level Warning -Text "Lock wait timeout (unreadable lock)"
                            return $null
                        }
                        
                        Start-Sleep -Seconds 2
                        continue
                    }
                } catch {
                    # Can't even check file age - be very conservative
                    Write-SAVerbose -Label "Lock" -Text "Cannot check lock file age - assuming held"
                    if (-not $Wait) {
                        return $null
                    }
                    Start-Sleep -Seconds 2
                    continue
                }
            }
        }
        
        # Try to create lock file atomically
        # Include process start time to prevent PID reuse false-positives
        # Use Unix timestamp (epoch seconds) for bulletproof cross-version compatibility
        $currentProcess = Get-Process -Id $PID
        $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
        $processStartUtc = $currentProcess.StartTime.ToUniversalTime()
        $processStartUnix = [long](($processStartUtc - $epoch).TotalSeconds)
        
        $lockData = @{
            pid                  = $PID
            processStartTimeUnix = $processStartUnix  # Unix timestamp (seconds since 1970-01-01 UTC)
            processStartTime     = $processStartUtc.ToString('o')  # Human-readable backup for debugging
            hostname             = $env:COMPUTERNAME
            startedAt            = (Get-Date).ToString('o')
            version              = 3  # Bump version for new format
        }
        
        try {
            # Use .NET for atomic file creation
            $lockJson = $lockData | ConvertTo-Json -Compress
            $fs = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($lockJson)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush($true)  # Flush to disk before closing
                $acquired = $true
            } finally {
                $fs.Close()
                $fs.Dispose()
            }
        } catch [System.IO.IOException] {
            # File already exists (race condition), retry
            if ($Wait) {
                Start-Sleep -Milliseconds 500
                continue
            }
            return $null
        }
        
    } while (-not $acquired -and $Wait -and ((Get-Date) - $startTime).TotalSeconds -lt $WaitTimeoutSeconds)
    
    if ($acquired) {
        Write-SAVerbose -Label "Lock" -Text "Acquired (PID $PID)"
        Write-SALockDiagnostic -QueueRoot $QueueRoot -Action 'acquire' -Reason "Lock acquired successfully"
        return @{
            Path      = $lockPath
            Pid       = $PID
            StartedAt = Get-Date
            Released  = $false
            QueueRoot = $QueueRoot  # Store for diagnostic logging on release
        }
    }
    
    return $null
}

function Unlock-SAGlobalLock {
    <#
    .SYNOPSIS
        Releases the global worker lock.
    .PARAMETER Lock
        Lock object from Get-SAGlobalLock.
    .EXAMPLE
        Unlock-SAGlobalLock -Lock $lock
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Lock
    )
    
    if ($null -eq $Lock) {
        return
    }
    
    if ($Lock.Released) {
        return
    }
    
    $lockPath = $Lock.Path
    $queueRoot = if ($Lock.QueueRoot) { $Lock.QueueRoot } else { Split-Path -Parent $lockPath }
    
    if (Test-Path -LiteralPath $lockPath) {
        # Verify we own the lock before releasing
        $lockInfo = Get-SALockInfo -LockPath $lockPath
        
        if ($null -ne $lockInfo -and $lockInfo.pid -eq $PID) {
            try {
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
                Write-SAVerbose -Label "Lock" -Text "Released"
                Write-SALockDiagnostic -QueueRoot $queueRoot -Action 'release' -Reason "Lock released normally"
            } catch {
                Write-SAOutcome -Level Warning -Text "Failed to release lock: $_"
                Write-SALockDiagnostic -QueueRoot $queueRoot -Action 'error' -Reason "Failed to release: $_"
            }
        } else {
            Write-SAOutcome -Level Warning -Text "Lock owned by different process, not releasing"
            Write-SALockDiagnostic -QueueRoot $queueRoot -Action 'error' -LockInfo $lockInfo -Reason "Lock owned by different process (PID: $($lockInfo.pid))"
        }
    }
    
    $Lock.Released = $true
}

function Test-SAGlobalLock {
    <#
    .SYNOPSIS
        Tests if the global lock is currently held.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .OUTPUTS
        $true if lock is held, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot
    )
    
    $lockPath = Join-Path -Path $QueueRoot -ChildPath '.lock'
    
    if (-not (Test-Path -LiteralPath $lockPath)) {
        return $false
    }
    
    $lockInfo = Get-SALockInfo -LockPath $lockPath
    
    if ($null -eq $lockInfo) {
        return $false
    }
    
    # Check if PID is alive AND belongs to the same process (prevents PID reuse)
    return Test-SAProcessAlive -Pid $lockInfo.pid -ProcessStartTime $lockInfo.processStartTime
}

function Get-SAGlobalLockInfo {
    <#
    .SYNOPSIS
        Gets information about the current lock holder.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .OUTPUTS
        Lock info object or $null if not locked.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot
    )
    
    $lockPath = Join-Path -Path $QueueRoot -ChildPath '.lock'
    
    if (-not (Test-Path -LiteralPath $lockPath)) {
        return $null
    }
    
    return Get-SALockInfo -LockPath $lockPath
}

# --- Private helper functions ---

function Write-SALockDiagnostic {
    <#
    .SYNOPSIS
        Writes lock-related events to a diagnostic log file.
    .DESCRIPTION
        Records lock acquisition, release, and contention events to a separate
        diagnostic log file for troubleshooting concurrency issues.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet('acquire', 'release', 'remove_stale', 'remove_corrupt', 'contention', 'error')]
        [string]$Action,
        
        [Parameter()]
        [hashtable]$LockInfo,
        
        [Parameter()]
        [string]$Reason
    )
    
    try {
        $diagnosticPath = Join-Path -Path $QueueRoot -ChildPath '.lock-diagnostic.log'
        
        $entry = @{
            timestamp = (Get-Date).ToString('o')
            action    = $Action
            pid       = $PID
            hostname  = $env:COMPUTERNAME
        }
        
        if ($LockInfo) {
            $entry['lockPid'] = $LockInfo.pid
            $entry['lockStartedAt'] = if ($LockInfo.startedAt) { $LockInfo.startedAt.ToString('o') } else { $null }
            $entry['lockProcessStartTime'] = if ($LockInfo.processStartTime) { $LockInfo.processStartTime.ToString('o') } else { $null }
        }
        
        if ($Reason) {
            $entry['reason'] = $Reason
        }
        
        # Get process start time for this process
        try {
            $currentProcess = Get-Process -Id $PID
            $entry['processStartTime'] = $currentProcess.StartTime.ToUniversalTime().ToString('o')
        } catch {
            $entry['processStartTime'] = 'unknown'
        }
        
        $line = "[$($entry.timestamp)] $Action | PID: $PID | " + 
                $(if ($LockInfo) { "LockPID: $($LockInfo.pid) | " } else { "" }) +
                $(if ($Reason) { "Reason: $Reason" } else { "" })
        
        # Truncate if over 1MB to prevent unbounded growth
        if ((Test-Path -LiteralPath $diagnosticPath) -and
            (Get-Item -LiteralPath $diagnosticPath -ErrorAction SilentlyContinue).Length -gt 1MB) {
            # Keep last ~500KB of log
            $content = Get-Content -LiteralPath $diagnosticPath -Tail 5000 -ErrorAction SilentlyContinue
            $content | Set-Content -LiteralPath $diagnosticPath -Encoding UTF8 -ErrorAction SilentlyContinue
        }

        # Append to diagnostic log (create if doesn't exist)
        # Note: Not echoing to verbose - diagnostic file is for forensics only
        Add-Content -LiteralPath $diagnosticPath -Value $line -ErrorAction SilentlyContinue
    } catch {
        # Don't let diagnostic logging failures affect the main flow
        # Silently ignore - diagnostic logging is best-effort
    }
}

function Get-SALockInfo {
    <#
    .SYNOPSIS
        Reads and parses lock file.
    .DESCRIPTION
        Reads the lock file with retry logic to handle file system race conditions
        where the file might not be fully visible immediately after creation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath,
        
        [Parameter()]
        [int]$MaxRetries = 3,
        
        [Parameter()]
        [int]$RetryDelayMs = 100
    )
    
    if (-not (Test-Path -LiteralPath $LockPath)) {
        return $null
    }
    
    # Retry logic to handle file system sync delays
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $json = Get-Content -LiteralPath $LockPath -Raw -ErrorAction Stop
            
            # Check for empty or whitespace-only content
            if ([string]::IsNullOrWhiteSpace($json)) {
                if ($attempt -lt $MaxRetries) {
                    # Retry silently - only log final failure
                    Start-Sleep -Milliseconds $RetryDelayMs
                    continue
                }
                # Final attempt failed - this is unusual, worth logging
                Write-SAVerbose -Label "Lock" -Text "Lock file empty after $MaxRetries attempts"
                return $null
            }
            
            $data = $json | ConvertFrom-Json -ErrorAction Stop
            
            # Parse processStartTime from Unix timestamp (v3+)
            # Unix timestamps are bulletproof - no timezone/parsing ambiguity
            $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
            $processStartTime = $null
            
            if ($null -ne $data.processStartTimeUnix) {
                $processStartTime = $epoch.AddSeconds([long]$data.processStartTimeUnix)
                # Note: Debug details (Kind, timestamps) omitted from verbose - see diagnostic file
            }
            
            # Parse startedAt (lock creation time)
            $startedAt = $null
            if ($data.startedAt) {
                try {
                    $startedAt = [datetime]::Parse(
                        $data.startedAt,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind
                    )
                } catch {
                    $startedAt = [datetime]$data.startedAt
                }
            }
            
            return @{
                pid              = [int]$data.pid
                processStartTime = $processStartTime
                hostname         = $data.hostname
                startedAt        = $startedAt
                version          = if ($data.version) { [int]$data.version } else { 1 }
            }
        } catch {
            if ($attempt -lt $MaxRetries) {
                # Retry silently - only log final failure
                Start-Sleep -Milliseconds $RetryDelayMs
                continue
            }
            # Final attempt failed - this is unusual, worth logging
            Write-SAVerbose -Label "Lock" -Text "Cannot read lock file: $($_.Exception.Message)"
            return $null
        }
    }
    
    return $null
}

function Test-SALockStale {
    <#
    .SYNOPSIS
        Tests if a lock is stale (dead PID, PID reused, or timeout).
    .DESCRIPTION
        A lock is considered stale if:
        1. The lock-holding process is no longer running (PID dead) - local machine only
        2. The PID was reused by a different process (start time mismatch) - local machine only
        3. The lock has been held for longer than StaleMinutes
        
        For CROSS-MACHINE scenarios (lock held by different hostname):
        - PID validation is skipped (PIDs are local to each machine)
        - Only the StaleMinutes timeout is used for staleness detection
        
        When in doubt, this function returns $false (not stale) to prevent
        incorrectly stealing locks from active workers.
        
        Emits a single verbose summary line rather than multiple detailed lines.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$LockInfo,
        
        [Parameter()]
        [int]$StaleMinutes = 15,
        
        [Parameter()]
        [string]$QueueRoot = $null
    )
    
    $lockHostname = $LockInfo.hostname
    $currentHostname = $env:COMPUTERNAME
    $isRemoteLock = $lockHostname -and ($lockHostname -ne $currentHostname)
    $lockPid = $LockInfo.pid
    
    # Calculate lock age
    $ageMinutes = 0
    if ($null -ne $LockInfo.startedAt) {
        $age = (Get-Date) - $LockInfo.startedAt
        $ageMinutes = [int]$age.TotalMinutes
    }
    
    if ($isRemoteLock) {
        # CROSS-MACHINE: Lock held by different machine
        # We CANNOT validate the PID - it's meaningless across machines
        # Only rely on the StaleMinutes timeout
        
        if ($null -ne $LockInfo.startedAt -and $age.TotalMinutes -ge $StaleMinutes) {
            Write-SAVerbose -Label "Lock" -Text "Stale (remote: $lockHostname, $ageMinutes min old, threshold: $StaleMinutes min)"
            return $true
        }
        
        Write-SAVerbose -Label "Lock" -Text "Active (remote: $lockHostname, PID $lockPid, $ageMinutes min old)"
        return $false
    }
    
    # SAME MACHINE: Can validate PID
    # Check if PID is still alive AND belongs to the same process (prevents PID reuse)
    $processAlive = Test-SAProcessAlive -Pid $lockPid -ProcessStartTime $LockInfo.processStartTime -QueueRoot $QueueRoot
    
    if (-not $processAlive) {
        Write-SAVerbose -Label "Lock" -Text "Stale (PID $lockPid not alive)"
        return $true
    }
    
    # Check if lock is too old (safety timeout for hung processes)
    if ($null -ne $LockInfo.startedAt -and $age.TotalMinutes -ge $StaleMinutes) {
        Write-SAVerbose -Label "Lock" -Text "Stale (PID $lockPid, $ageMinutes min old, threshold: $StaleMinutes min)"
        return $true
    }
    
    Write-SAVerbose -Label "Lock" -Text "Active (PID $lockPid, $ageMinutes min old, threshold: $StaleMinutes min)"
    return $false
}

function Test-SAProcessAlive {
    <#
    .SYNOPSIS
        Tests if a process with given PID is running and matches the expected start time.
    .DESCRIPTION
        Windows can reuse PIDs after a process dies. To prevent false-positive lock detection
        (where a different process has the same PID), we validate both the PID exists AND
        the process start time matches what's recorded in the lock file.
        
        IMPORTANT: When in doubt, this function returns $true (process is alive) to prevent
        incorrectly stealing locks from running workers. False positives (thinking a dead
        process is alive) just cause waiting; false negatives (thinking a live process is dead)
        cause data corruption from concurrent workers.
        
        This function uses .NET directly for maximum reliability across PowerShell versions.
        
        Diagnostic details are written to .lock-process-check.log for forensic analysis,
        but not to Write-Verbose (to avoid verbose noise).
    .PARAMETER Pid
        Process ID to check.
    .PARAMETER ProcessStartTime
        Expected process start time (from lock file). If $null, only checks if PID exists
        (backward compatibility with v1 lock files).
    .PARAMETER QueueRoot
        Optional queue root path for diagnostic logging.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Pid,
        
        [Parameter()]
        [AllowNull()]
        [datetime]$ProcessStartTime = $null,
        
        [Parameter()]
        [string]$QueueRoot = $null
    )
    
    # Helper to log diagnostic info to file only (not verbose - keeps console clean)
    $logDiag = {
        param([string]$Message)
        if ($QueueRoot) {
            try {
                $diagPath = Join-Path $QueueRoot '.lock-process-check.log'
                $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
                "$timestamp | PID: $Pid | $Message" | Add-Content -Path $diagPath -ErrorAction SilentlyContinue
            } catch { }
        }
    }
    
    # Use .NET directly - more reliable than Get-Process cmdlet across PowerShell versions
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($Pid)
        & $logDiag "GetProcessById succeeded - process exists"
    } catch [System.ArgumentException] {
        # This is the ONLY exception that definitively means "process does not exist"
        # ArgumentException: "Process with an Id of X is not running"
        & $logDiag "ArgumentException: Process does not exist"
        return $false
    } catch [System.InvalidOperationException] {
        # Process existed but exited before we could get info
        & $logDiag "InvalidOperationException: Process exited during check"
        return $false
    } catch {
        # ANY other exception - be conservative and assume process is alive
        # This includes: UnauthorizedAccessException, Win32Exception, etc.
        & $logDiag "Unexpected exception: $($_.Exception.Message) - assuming alive"
        return $true
    }
    
    # Double-check we got a process object
    if ($null -eq $process) {
        & $logDiag "Process object is null - assuming alive (conservative)"
        return $true
    }
    
    # Check if process has exited (it might have died between GetProcessById and now)
    try {
        if ($process.HasExited) {
            & $logDiag "Process.HasExited is true - process is dead"
            return $false
        }
    } catch {
        # Can't check HasExited - be conservative
        & $logDiag "Cannot check HasExited - assuming alive"
        return $true
    }
    
    # If no start time provided (v1 lock file), just verify PID exists
    if ($null -eq $ProcessStartTime) {
        & $logDiag "PID exists, no start time to validate (v1 lock) - alive"
        return $true
    }
    
    # Try to validate process start time (prevents PID reuse false-positives)
    try {
        $actualStartTime = $process.StartTime.ToUniversalTime()
        
        # The expected time from the lock file should already be UTC
        # (v3 uses Unix timestamps which are inherently UTC, v2 should be parsed as UTC)
        # Use SpecifyKind to ensure comparison works even if Kind got mangled
        $expectedStartTime = [datetime]::SpecifyKind($ProcessStartTime, [System.DateTimeKind]::Utc)
        
        # Use tick-based comparison for precision (avoids floating-point issues)
        # Allow 30 second tolerance for clock precision, serialization, etc.
        $tickDiff = [Math]::Abs($actualStartTime.Ticks - $expectedStartTime.Ticks)
        $secondsDiff = $tickDiff / [TimeSpan]::TicksPerSecond
        
        & $logDiag "Start time check: $([int]$secondsDiff)s difference (30s threshold)"
        
        if ($secondsDiff -gt 30) {
            # Large time difference suggests PID was reused by a different process
            & $logDiag "START TIME MISMATCH >30s - PID likely reused"
            return $false
        }
        
        & $logDiag "PID verified - alive"
        return $true
        
    } catch {
        # Cannot access StartTime property - be CONSERVATIVE
        & $logDiag "Cannot access StartTime - assuming alive"
        return $true
    } finally {
        # Clean up the process object
        if ($null -ne $process) {
            try { $process.Dispose() } catch { }
        }
    }
}