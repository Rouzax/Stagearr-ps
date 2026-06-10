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

# Module-scope reference to the lock currently held by this worker (set by Get-SAGlobalLock,
# cleared by Unlock-SAGlobalLock). Used by the import guard and stolen-flag checks.
$script:SACurrentLock = $null

# Self-contained heartbeat loop body. Runs in a SEPARATE runspace with NO Stagearr module
# loaded, so it may use ONLY .NET primitives plus ConvertTo-Json / ConvertFrom-Json
# (Microsoft.PowerShell.Utility is present in a default runspace). Arguments, in order:
#   $lockPath, $queueRoot, $identity (hashtable), $intervalMs, $stop (ManualResetEventSlim),
#   $shared (synchronized hashtable with a 'stolen' key).
$script:SAHeartbeatScriptText = @'
param($lockPath, $queueRoot, $identity, $intervalMs, $stop, $shared)
while (-not $stop.Wait($intervalMs)) {
    try {
        if (-not [System.IO.File]::Exists($lockPath)) { $shared.stolen = $true; break }
        $cur = [System.IO.File]::ReadAllText($lockPath) | ConvertFrom-Json
        if ($cur.pid -ne $identity.pid -or
            $cur.hostname -ne $identity.hostname -or
            [long]$cur.processStartTimeUnix -ne [long]$identity.processStartTimeUnix) {
            # Lock was stolen: stop refreshing (do not clobber the new owner) and exit the loop.
            $shared.stolen = $true
            break
        }
        $data = @{
            pid                  = $identity.pid
            processStartTimeUnix = $identity.processStartTimeUnix
            processStartTime     = $identity.processStartTime
            hostname             = $identity.hostname
            startedAt            = $identity.startedAt
            heartbeatAt          = ([datetime]::UtcNow).ToString('o')
            version              = 4
        }
        $json = $data | ConvertTo-Json -Compress
        $tmpFile = [System.IO.Path]::Combine($queueRoot, '.lock.hb-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($tmpFile, $json)
        try {
            # Atomic overwrite. Replace(src, dst, $null) works on .NET Framework (Windows/PS5.1).
            # On Linux/.NET 5+ a null backup path throws; fall back to Replace with a real backup
            # path (works on both runtimes) then clean up the backup file.
            try {
                [System.IO.File]::Replace($tmpFile, $lockPath, $null)
            } catch {
                # Unique backup name so two workers sharing a network queue folder never collide.
                $backupFile = $lockPath + '.hb-bak-' + [guid]::NewGuid().ToString('N')
                [System.IO.File]::Replace($tmpFile, $lockPath, $backupFile)
                if ([System.IO.File]::Exists($backupFile)) { [System.IO.File]::Delete($backupFile) }
            }
        } catch {
            # Lock vanished between the ownership check and the replace (rare steal race):
            # drop our temp file and let the next tick re-evaluate ownership.
            if ([System.IO.File]::Exists($tmpFile)) { [System.IO.File]::Delete($tmpFile) }
        }
    } catch {
        # Best-effort: a failed beat (share unreachable, AV lock) is non-fatal.
        # The import guard / stolen flag handle any resulting steal.
    }
}
'@

function Get-SAGlobalLock {
    <#
    .SYNOPSIS
        Acquires the global worker lock.
    .DESCRIPTION
        Creates a lock file with PID and timestamp. Handles stale lock recovery.
        Returns a lock object that must be released with Unlock-SAGlobalLock.
    .PARAMETER QueueRoot
        Path to the queue root directory.
    .PARAMETER StaleSeconds
        Seconds after which a lock with no recent heartbeat is considered stale (default: 120).
    .PARAMETER HeartbeatSeconds
        Interval in seconds between heartbeat refreshes (default: 30).
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
        [int]$StaleSeconds = 120,

        [Parameter()]
        [int]$HeartbeatSeconds = 30,

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
                $isStale = Test-SALockStale -LockInfo $existingLock -StaleSeconds $StaleSeconds -QueueRoot $QueueRoot
                
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

                    # Atomic compare-and-swap steal: rename the stale lock to a unique
                    # name. Exactly one racer wins the rename; losers re-loop. This avoids
                    # the remove-then-create TOCTOU where two workers both "win".
                    $stealName = "$lockPath.steal-$([guid]::NewGuid().ToString('N'))"
                    try {
                        [System.IO.File]::Move($lockPath, $stealName)
                        Remove-Item -LiteralPath $stealName -Force -ErrorAction SilentlyContinue
                    } catch {
                        # Lost the race (another worker already moved it, or holder resumed).
                        Write-SAVerbose -Label "Lock" -Text "Lost steal race, retrying"
                        if ($Wait) { Start-Sleep -Milliseconds 250; continue }
                        return $null
                    }
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
                    
                    if ($fileAge.TotalSeconds -ge $StaleSeconds) {
                        # Lock file is very old and unreadable - likely truly corrupt
                        Write-SAOutcome -Level Warning -Text "Removing unreadable lock file (age: $([int]$fileAge.TotalSeconds) seconds)"
                        Write-SALockDiagnostic -QueueRoot $QueueRoot -Action 'remove_corrupt' -Reason "Unreadable lock file, age: $([int]$fileAge.TotalSeconds) seconds"
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
            heartbeatAt          = ([datetime]::UtcNow).ToString('o')
            version              = 4
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

        $identity = @{
            pid                  = $PID
            hostname             = $env:COMPUTERNAME
            processStartTimeUnix = $processStartUnix
            processStartTime     = $processStartUtc.ToString('o')
            startedAt            = $lockData.startedAt
        }

        try {
            $heartbeat = Start-SALockHeartbeat -LockPath $lockPath -QueueRoot $QueueRoot `
                -Identity $identity -IntervalMs ($HeartbeatSeconds * 1000)
        } catch {
            # Without a heartbeat the lock would be stolen mid-job: fail acquisition.
            Write-SAOutcome -Level Warning -Text "Heartbeat failed to start, releasing lock: $($_.Exception.Message)"
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
            return $null
        }

        $script:SACurrentLock = @{
            Path      = $lockPath
            Pid       = $PID
            StartedAt = Get-Date
            Released  = $false
            QueueRoot = $QueueRoot
            Heartbeat = $heartbeat
        }
        return $script:SACurrentLock
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

    # Stop the heartbeat BEFORE removing the lock file so a final in-flight beat
    # cannot resurrect a just-deleted lock.
    if ($Lock.Heartbeat) {
        Stop-SALockHeartbeat -Heartbeat $Lock.Heartbeat
        $Lock.Heartbeat = $null
    }

    $lockPath = $Lock.Path
    $queueRoot = if ($Lock.QueueRoot) { $Lock.QueueRoot } else { Split-Path -Parent $lockPath }
    
    if (Test-Path -LiteralPath $lockPath) {
        # Verify we still own the lock before releasing (full pid + hostname + start-time
        # match, so we never delete a lock that was legitimately stolen from us).
        $lockInfo = Get-SALockInfo -LockPath $lockPath

        if (Test-SALockOwnedBySelf -QueueRoot $queueRoot) {
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

    if ($script:SACurrentLock -and $script:SACurrentLock.Path -eq $Lock.Path) {
        $script:SACurrentLock = $null
    }
}

function Start-SALockHeartbeat {
    <#
    .SYNOPSIS
        Starts a background runspace that refreshes the lock's heartbeatAt and detects theft.
    .OUTPUTS
        Hashtable: @{ Runspace; PowerShell; Async; Stop; Shared } or throws on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$LockPath,
        [Parameter(Mandatory = $true)] [string]$QueueRoot,
        [Parameter(Mandatory = $true)] [hashtable]$Identity,
        [Parameter()] [int]$IntervalMs = 30000
    )

    $stop = [System.Threading.ManualResetEventSlim]::new($false)
    $shared = [hashtable]::Synchronized(@{ stolen = $false })

    $rs = $null
    $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:SAHeartbeatScriptText).
            AddArgument($LockPath).AddArgument($QueueRoot).AddArgument($Identity).
            AddArgument($IntervalMs).AddArgument($stop).AddArgument($shared)
        # $Identity is passed by reference into the runspace; do not mutate it after this call.
        $async = $ps.BeginInvoke()
    } catch {
        # Partial-start failure: dispose anything created so we do not leak a thread/handle.
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        if ($null -ne $rs) { try { $rs.Close(); $rs.Dispose() } catch { } }
        try { $stop.Dispose() } catch { }
        throw
    }

    return @{
        Runspace   = $rs
        PowerShell = $ps
        Async      = $async
        Stop       = $stop
        Shared     = $shared
    }
}

function Stop-SALockHeartbeat {
    <#
    .SYNOPSIS
        Signals the heartbeat runspace to stop, waits for it to end, and disposes it.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [AllowNull()] $Heartbeat
    )
    if ($null -eq $Heartbeat) { return }
    try { $Heartbeat.Stop.Set() } catch { }
    try { if ($Heartbeat.Async) { $null = $Heartbeat.PowerShell.EndInvoke($Heartbeat.Async) } } catch { }
    try { $Heartbeat.PowerShell.Dispose() } catch { }
    try { $Heartbeat.Runspace.Close(); $Heartbeat.Runspace.Dispose() } catch { }
    try { $Heartbeat.Stop.Dispose() } catch { }
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
    if ($null -eq $lockInfo) { return $false }

    # Held == not stale (heartbeat fresh for v4, PID/age for legacy)
    return (-not (Test-SALockStale -LockInfo $lockInfo -StaleSeconds 120 -QueueRoot $QueueRoot))
}

function Test-SALockOwnedBySelf {
    <#
    .SYNOPSIS
        Returns $true only if the lock file in QueueRoot is currently owned by THIS process.
    .DESCRIPTION
        Compares pid + hostname + process start time (Unix seconds) against this process.
        Used by the import guard to refuse importing if the lock was stolen mid-job.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueRoot
    )

    $lockPath = Join-Path -Path $QueueRoot -ChildPath '.lock'
    $info = Get-SALockInfo -LockPath $lockPath
    if ($null -eq $info) { return $false }

    if ($info.pid -ne $PID) { return $false }
    if ($info.hostname -ne $env:COMPUTERNAME) { return $false }

    # Compare process start time (Unix seconds) to defeat PID reuse
    $epoch = [datetime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    $myUnix = [long](((Get-Process -Id $PID).StartTime.ToUniversalTime() - $epoch).TotalSeconds)
    if ($null -ne $info.processStartTimeUnix -and [long]$info.processStartTimeUnix -ne $myUnix) {
        return $false
    }

    return $true
}

function Test-SAImportLockOk {
    <#
    .SYNOPSIS
        Returns $true if it is safe to import: either no worker lock is held
        (e.g. -Rerun runs without Start-SAWorker), or this process still owns it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($null -eq $script:SACurrentLock) { return $true }
    return (Test-SALockOwnedBySelf -QueueRoot $script:SACurrentLock.QueueRoot)
}

function Test-SALockStolen {
    <#
    .SYNOPSIS
        Returns $true if the heartbeat has detected our lock was stolen.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($null -eq $script:SACurrentLock) { return $false }
    if ($null -eq $script:SACurrentLock.Heartbeat) { return $false }
    return [bool]$script:SACurrentLock.Heartbeat.Shared.stolen
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
            
            # Parse heartbeatAt (v4); RoundtripKind keeps the 'o'/Z format as UTC.
            # ConvertFrom-Json may auto-convert ISO strings to [datetime]; handle both cases.
            $heartbeatAt = $null
            if ($data.heartbeatAt) {
                try {
                    if ($data.heartbeatAt -is [datetime]) {
                        $heartbeatAt = $data.heartbeatAt
                    } else {
                        $heartbeatAt = [datetime]::Parse(
                            [string]$data.heartbeatAt,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind
                        )
                    }
                } catch {
                    $heartbeatAt = $null
                }
            }

            return @{
                pid                  = [int]$data.pid
                processStartTime     = $processStartTime
                processStartTimeUnix = if ($null -ne $data.processStartTimeUnix) { [long]$data.processStartTimeUnix } else { $null }
                hostname             = $data.hostname
                startedAt            = $startedAt
                heartbeatAt          = $heartbeatAt
                version              = if ($data.version) { [int]$data.version } else { 1 }
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
        Tests if a lock is stale using heartbeat age (v4) or startedAt fallback (v3 legacy).
    .DESCRIPTION
        v4 locks: a lock is stale when no heartbeat has been written for StaleSeconds.
        Same-machine fast-path: a dead PID is stale immediately regardless of heartbeat age.
        Clock-backward safety: a future-dated heartbeat is treated as alive (never stolen).

        v3 legacy fallback (no heartbeatAt): uses startedAt age for remote locks, and
        PID liveness for same-machine locks.

        When in doubt, returns $false (not stale) to prevent incorrectly stealing locks.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$LockInfo,

        [Parameter()]
        [int]$StaleSeconds = 120,

        [Parameter()]
        [string]$QueueRoot = $null
    )

    $lockHostname = $LockInfo.hostname
    $currentHostname = $env:COMPUTERNAME
    $isRemoteLock = $lockHostname -and ($lockHostname -ne $currentHostname)
    $lockPid = $LockInfo.pid

    # --- v4: heartbeat-based staleness ---
    if ($null -ne $LockInfo.heartbeatAt) {
        $age = [datetime]::UtcNow - $LockInfo.heartbeatAt.ToUniversalTime()

        # Clock-backward / future heartbeat: treat as alive, never steal
        if ($age.TotalSeconds -lt 0) {
            Write-SAVerbose -Label "Lock" -Text "Active (heartbeat in future; clock skew, treating as alive)"
            return $false
        }

        # Same machine: dead PID is stale immediately (fast crash recovery)
        if (-not $isRemoteLock) {
            $processAlive = Test-SAProcessAlive -Pid $lockPid -ProcessStartTime $LockInfo.processStartTime -QueueRoot $QueueRoot
            if (-not $processAlive) {
                Write-SAVerbose -Label "Lock" -Text "Stale (PID $lockPid not alive)"
                return $true
            }
        }

        if ($age.TotalSeconds -ge $StaleSeconds) {
            Write-SAVerbose -Label "Lock" -Text "Stale (no heartbeat for $([int]$age.TotalSeconds)s, threshold ${StaleSeconds}s)"
            return $true
        }

        Write-SAVerbose -Label "Lock" -Text "Active (heartbeat $([int]$age.TotalSeconds)s ago, threshold ${StaleSeconds}s)"
        return $false
    }

    # --- v3 legacy fallback (no heartbeat): upgrade-transition only ---
    $startedAge = $null
    if ($null -ne $LockInfo.startedAt) {
        $startedAge = (Get-Date) - $LockInfo.startedAt
    }

    if ($isRemoteLock) {
        if ($null -ne $startedAge -and $startedAge.TotalSeconds -ge $StaleSeconds) {
            Write-SAVerbose -Label "Lock" -Text "Stale (legacy remote: $lockHostname, $([int]$startedAge.TotalSeconds)s old)"
            return $true
        }
        Write-SAVerbose -Label "Lock" -Text "Active (legacy remote: $lockHostname)"
        return $false
    }

    $processAlive = Test-SAProcessAlive -Pid $lockPid -ProcessStartTime $LockInfo.processStartTime -QueueRoot $QueueRoot
    if (-not $processAlive) {
        Write-SAVerbose -Label "Lock" -Text "Stale (legacy, PID $lockPid not alive)"
        return $true
    }
    if ($null -ne $startedAge -and $startedAge.TotalSeconds -ge $StaleSeconds) {
        Write-SAVerbose -Label "Lock" -Text "Stale (legacy, PID $lockPid, $([int]$startedAge.TotalSeconds)s old)"
        return $true
    }
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