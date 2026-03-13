#Requires -Version 5.1
<#
.SYNOPSIS
    Filesystem log renderer for Stagearr output events
.DESCRIPTION
    Generates plain-text log files for forensic analysis:
    - UTF-8 encoding, no ANSI codes
    - Includes verbose-level events by default
    - Structured format: [HH:mm:ss] [LEVEL] [Phase] Label: Message
    - Header with job metadata
    - Footer with summary and duration
    
    Per OUTPUT-STYLE-GUIDE: "Logs written to disk exist so an operator can 
    diagnose later, share a report, or audit a run."
#>

#region Module State

$script:SAFileLogState = @{
    LogPath        = ''
    LogFolder      = ''
    StartTime      = $null
    Initialized    = $false
    EventsWritten  = 0
    ToolVersions   = @{}  # Tool name -> version string
    LogSaved       = $false  # Prevents double-saving
}

# Buffer for deferred writing (allows header rewrite)
$script:SAFileLogBuffer = [System.Collections.Generic.List[string]]::new()

#endregion

#region Initialization

function Initialize-SAFileLogRenderer {
    <#
    .SYNOPSIS
        Initializes the filesystem log renderer.
    .DESCRIPTION
        Sets up log file path and prepares for logging.
        Called automatically by Initialize-SAOutputSystem.
    .PARAMETER LogFolder
        Folder to write log files to
    .PARAMETER JobName
        Job name for log filename
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$LogFolder = '',
        
        [Parameter()]
        [string]$JobName = ''
    )
    
    $script:SAFileLogState = @{
        LogPath        = ''
        LogFolder      = $LogFolder
        StartTime      = Get-Date
        Initialized    = $true
        EventsWritten  = 0
        ToolVersions   = @{}
        LogSaved       = $false
    }
    
    $script:SAFileLogBuffer = [System.Collections.Generic.List[string]]::new()
    
    # Generate log path if folder provided
    if (-not [string]::IsNullOrWhiteSpace($LogFolder)) {
        $script:SAFileLogState.LogPath = Get-SAFileLogPath -Folder $LogFolder -JobName $JobName
    }
}

function Reset-SAFileLogRenderer {
    <#
    .SYNOPSIS
        Resets filesystem log renderer state.
    #>
    [CmdletBinding()]
    param()
    
    $script:SAFileLogState = @{
        LogPath        = ''
        LogFolder      = ''
        StartTime      = $null
        Initialized    = $false
        EventsWritten  = 0
        ToolVersions   = @{}
        LogSaved       = $false
    }
    $script:SAFileLogBuffer = [System.Collections.Generic.List[string]]::new()
}

function Get-SAFileLogPath {
    <#
    .SYNOPSIS
        Generates the log file path.
    .PARAMETER Folder
        Log folder
    .PARAMETER JobName
        Job name for filename
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Folder,
        
        [Parameter()]
        [string]$JobName = ''
    )
    
    # Ensure folder exists
    if (-not (Test-Path -LiteralPath $Folder)) {
        New-Item -Path $Folder -ItemType Directory -Force | Out-Null
    }
    
    # Generate filename: "2024-01-15 14.30.45-JobName.log"
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH.mm.ss'
    
    $safeName = if ([string]::IsNullOrWhiteSpace($JobName)) {
        'job'
    } else {
        # Sanitize filename
        $JobName -replace '[<>:"/\\|?*]', '_'
    }
    
    $fileName = "$timestamp-$safeName.log"
    
    return Join-Path -Path $Folder -ChildPath $fileName
}

function Set-SAFileLogPath {
    <#
    .SYNOPSIS
        Sets the log file path explicitly.
    .PARAMETER Path
        Full path to log file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    $script:SAFileLogState.LogPath = $Path
    $script:SAFileLogState.LogFolder = Split-Path -Path $Path -Parent
}

#endregion

#region Event Rendering

function Write-SAFileLogEvent {
    <#
    .SYNOPSIS
        Renders a single event to the log buffer.
    .DESCRIPTION
        Called by the event dispatcher for each event.
        Events are buffered and written to disk when Save-SAFileLog is called.
    .PARAMETER Event
        The event object to render
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    if (-not $script:SAFileLogState.Initialized) {
        return
    }
    
    # Format the event as a log line
    $line = Format-SAFileLogLine -Event $Event
    
    if (-not [string]::IsNullOrWhiteSpace($line)) {
        $script:SAFileLogBuffer.Add($line)
        $script:SAFileLogState.EventsWritten++
    }
}

function Format-SAFileLogLine {
    <#
    .SYNOPSIS
        Formats an event as a log file line.
    .PARAMETER Event
        Event to format
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    # Handle headers specially
    if ($Event.IsHeader) {
        return Format-SAFileLogHeader -Event $Event
    }
    
    # Format: [HH:mm:ss] [LEVEL] [Phase] Label: Message
    $timestamp = $Event.Timestamp.ToString('HH:mm:ss')
    
    # Level indicator (5 chars, padded)
    $levelStr = switch ($Event.Level) {
        'Success' { 'OK   ' }
        'Warning' { 'WARN ' }
        'Error'   { 'ERROR' }
        'Skip'    { 'SKIP ' }
        'Info'    { 'INFO ' }
        'Verbose' { 'VERB ' }
        default   { '     ' }
    }
    
    # Phase (optional, for context)
    $phaseStr = if ([string]::IsNullOrWhiteSpace($Event.Phase)) { '' } else { "[$($Event.Phase)] " }
    
    # Build message
    $message = Format-SAFileLogMessage -Event $Event
    
    # Label prefix
    $labelPrefix = if ([string]::IsNullOrWhiteSpace($Event.Label)) { '' } else { "$($Event.Label): " }
    
    return "[$timestamp] [$levelStr] $phaseStr$labelPrefix$message"
}

function Format-SAFileLogHeader {
    <#
    .SYNOPSIS
        Formats a section header for the log.
    .PARAMETER Event
        Header event
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    $timestamp = $Event.Timestamp.ToString('HH:mm:ss')
    $title = $Event.Text
    
    # Create a visual separator
    $separator = '-' * 60
    
    return @(
        ""
        "[$timestamp] $separator"
        "[$timestamp] --- $title ---"
        "[$timestamp] $separator"
    ) -join "`r`n"
}

function Format-SAFileLogMessage {
    <#
    .SYNOPSIS
        Formats the message portion of an event.
    .PARAMETER Event
        Event to format
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Event
    )
    
    $parts = @()
    
    # Batch prefix
    if ($null -ne $Event.BatchIndex -and $null -ne $Event.BatchTotal) {
        $parts += "[$($Event.BatchIndex)/$($Event.BatchTotal)]"
    }
    
    # Main text
    if (-not [string]::IsNullOrWhiteSpace($Event.Text)) {
        $parts += $Event.Text
    }
    
    # Duration
    if ($null -ne $Event.Duration -and $Event.Duration -gt 0) {
        $parts += "($($Event.Duration)s)"
    }
    
    # Details (verbose info) - filter out internal metadata keys starting with '_'
    if ($Event.Details -and $Event.Details.Count -gt 0) {
        $detailParts = $Event.Details.GetEnumerator() | 
            Where-Object { -not $_.Key.StartsWith('_') } |
            ForEach-Object { "$($_.Key)=$($_.Value)" }
        if ($detailParts) {
            $parts += "[" + ($detailParts -join ', ') + "]"
        }
    }
    
    return ($parts -join ' ')
}

#endregion

#region Log File Generation

function Save-SAFileLog {
    <#
    .SYNOPSIS
        Saves the accumulated log to disk.
    .DESCRIPTION
        Generates the complete log file with header, events, and footer.
        Call this at job completion.
    .PARAMETER Path
        Optional override for log file path
    .PARAMETER JobMetadata
        Optional job metadata for header
    .OUTPUTS
        Path to the saved log file
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$Path = '',
        
        [Parameter()]
        [hashtable]$JobMetadata = $null
    )
    
    # Determine path
    $logPath = if ([string]::IsNullOrWhiteSpace($Path)) {
        $script:SAFileLogState.LogPath
    } else {
        $Path
    }
    
    if ([string]::IsNullOrWhiteSpace($logPath)) {
        Write-SAVerbose -Label "FileLog" -Text "No path configured, skipping"
        return ''
    }
    
    # Prevent double-saving (finally blocks may call this after successful saves)
    if ($script:SAFileLogState.LogSaved) {
        Write-SAVerbose -Label "FileLog" -Text "Already saved"
        return ''  # Return empty to indicate no new save occurred
    }
    
    # Ensure directory exists
    $logDir = Split-Path -Path $logPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    
    # Build complete log content
    $content = [System.Collections.Generic.List[string]]::new()
    
    # Add header (with null safety)
    $header = Get-SAFileLogHeader -JobMetadata $JobMetadata
    if ($null -ne $header -and $header.Count -gt 0) {
        $content.AddRange([string[]]$header)
    }
    
    # Add events (with null safety)
    if ($null -ne $script:SAFileLogBuffer) {
        foreach ($line in $script:SAFileLogBuffer) {
            $content.Add($line)
        }
    }
    
    # Add footer (with null safety)
    $footer = Get-SAFileLogFooter
    if ($null -ne $footer -and $footer.Count -gt 0) {
        $content.AddRange([string[]]$footer)
    }
    
    # Write to file (UTF-8 without BOM)
    Write-SAFileLinesUtf8NoBom -Path $logPath -Lines $content.ToArray()
    
    # Mark as saved to prevent double-saving
    $script:SAFileLogState.LogSaved = $true
    
    Write-SAVerbose -Label "FileLog" -Text "Saved ($($script:SAFileLogState.EventsWritten) events)"
    
    return $logPath
}

function Get-SAFileLogHeader {
    <#
    .SYNOPSIS
        Generates the log file header.
    .DESCRIPTION
        Creates a header with:
        - Title and separator
        - Job metadata (start time, title, quality, group, label, hash, source)
        - External tool versions
        
        The header includes:
        - Started: Timestamp when job began
        - Title: Friendly media name (from FriendlyName or Name)
        - Quality: Resolution and source (e.g., "2160p WEB-DL Dolby Vision")
        - Group: Release group name
        - Label: qBittorrent label (movie, tv, etc.)
        - Hash: Torrent info hash
        - Source: Original source path
        
        Quality and Group are omitted for passthrough jobs (no ReleaseInfo).
    .PARAMETER JobMetadata
        Job metadata hashtable containing:
        - StartTime: DateTime
        - Name: Friendly display name (from FriendlyName or fallback)
        - Label: qBittorrent label
        - SourcePath: Original source path
        - TorrentHash: Torrent info hash (optional)
        - ReleaseInfo: Enriched ReleaseInfo object (optional, contains QualityLogDisplay, ReleaseGroup)
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [hashtable]$JobMetadata = $null
    )
    
    $separator = '=' * 80
    $lines = @()
    
    $lines += $separator
    $lines += "Stagearr Job Log"
    $lines += $separator

    # Version
    $moduleVersion = (Get-Module -Name 'Stagearr.Core').Version
    if ($null -ne $moduleVersion) {
        $lines += "Version:  $($moduleVersion.ToString())"
    }

    # Job info
    $meta = if ($null -ne $JobMetadata) { $JobMetadata } else { Get-SAJobMetadata }
    
    # Started timestamp
    if ($null -ne $meta.StartTime) {
        $lines += "Started:  $($meta.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    }
    
    # Title (renamed from Name per IMPLEMENTATION-PLAN-METADATA-DISPLAY.md)
    if (-not [string]::IsNullOrWhiteSpace($meta.Name)) {
        $lines += "Title:    $($meta.Name)"
    }
    
    # Quality (from enriched ReleaseInfo, omit for passthrough)
    if ($null -ne $meta.ReleaseInfo -and -not [string]::IsNullOrWhiteSpace($meta.ReleaseInfo.QualityLogDisplay)) {
        $lines += "Quality:  $($meta.ReleaseInfo.QualityLogDisplay)"
    }
    
    # Group (from ReleaseInfo, omit for passthrough)
    if ($null -ne $meta.ReleaseInfo -and -not [string]::IsNullOrWhiteSpace($meta.ReleaseInfo.ReleaseGroup)) {
        $lines += "Group:    $($meta.ReleaseInfo.ReleaseGroup)"
    }
    
    # Label
    if (-not [string]::IsNullOrWhiteSpace($meta.Label)) {
        $lines += "Label:    $($meta.Label)"
    }
    
    # Hash (torrent info hash)
    if (-not [string]::IsNullOrWhiteSpace($meta.TorrentHash)) {
        $lines += "Hash:     $($meta.TorrentHash)"
    }
    
    # Source path
    if (-not [string]::IsNullOrWhiteSpace($meta.SourcePath)) {
        $lines += "Source:   $($meta.SourcePath)"
    }
    
    # Update status (read from module state, same approach as email section)
    $updateState = Get-SAUpdateState
    if ($updateState.UpdateApplied) {
        $lines += "Update:   Updated from v$($updateState.OldVersion) to v$($updateState.NewVersion)"
    } elseif ($updateState.UpdateAvailable) {
        $lines += "Update:   v$($updateState.NewVersion) available"
    } elseif ($updateState.CheckPerformed) {
        $lines += "Update:   Up to date"
    }

    # External tool versions (per OUTPUT-STYLE-GUIDE: invaluable for troubleshooting)
    if ($script:SAFileLogState.ToolVersions -and $script:SAFileLogState.ToolVersions.Count -gt 0) {
        $lines += ""
        $lines += "--- External Tools ---"
        
        # PowerShell first (it's the runtime), then alphabetical
        $toolNames = @()
        if ($script:SAFileLogState.ToolVersions.ContainsKey('PowerShell')) {
            $toolNames += 'PowerShell'
        }
        $toolNames += $script:SAFileLogState.ToolVersions.Keys | Where-Object { $_ -ne 'PowerShell' } | Sort-Object
        
        foreach ($toolName in $toolNames) {
            $toolInfo = $script:SAFileLogState.ToolVersions[$toolName]
            
            if ($toolInfo -is [hashtable]) {
                $version = $toolInfo.Version
                $path = $toolInfo.Path
                
                if (-not [string]::IsNullOrWhiteSpace($path)) {
                    $lines += "$($toolName): $version ($path)"
                } else {
                    $lines += "$($toolName): $version"
                }
            } else {
                # String value (version only)
                $lines += "$($toolName): $toolInfo"
            }
        }
    } elseif ($null -ne $meta -and ($meta.Label -eq 'software' -or $meta.Label -eq 'ebook' -or $meta.Label -eq 'music')) {
        # Passthrough mode - show explicit message
        $lines += ""
        $lines += "--- External Tools ---"
        $lines += "(none required for passthrough)"
    }
    
    $lines += $separator
    $lines += ""
    
    return $lines
}

function Get-SAFileLogFooter {
    <#
    .SYNOPSIS
        Generates the log file footer.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    
    $separator = '=' * 80
    $lines = @()
    
    $lines += ""
    $lines += $separator
    
    # Summary statistics
    $events = Get-SAOutputEvents -IncludeVerbose
    $warningCount = @($events | Where-Object { $_.Level -eq 'Warning' }).Count
    $errorCount = @($events | Where-Object { $_.Level -eq 'Error' }).Count
    
    # Determine overall result
    $result = if ($errorCount -gt 0) {
        'Failed'
    } elseif ($warningCount -gt 0) {
        'Completed with warnings'
    } else {
        'Success'
    }
    
    $lines += "Result:   $result"
    
    # Duration
    $duration = Get-SAJobDuration
    $durationStr = if ($duration.TotalMinutes -ge 1) {
        $duration.ToString('mm\:ss')
    } else {
        "$([int]$duration.TotalSeconds)s"
    }
    $lines += "Duration: $durationStr"
    
    # Statistics
    $lines += "Events:   $($script:SAFileLogState.EventsWritten) logged"
    if ($warningCount -gt 0 -or $errorCount -gt 0) {
        $lines += "Issues:   $warningCount warnings, $errorCount errors"
    }
    
    $lines += $separator
    
    return $lines
}

#endregion

#region Utility Functions

function Set-SAFileLogToolVersions {
    <#
    .SYNOPSIS
        Sets all tool versions for the log header.
    .DESCRIPTION
        Stores tool version information that will be included in the log header
        when Save-SAFileLog is called. This ensures tool versions are visible
        even if verbose output wasn't enabled during the run.
    .PARAMETER ToolVersions
        Hashtable mapping tool names to version strings (or hashtable with Version and Path)
    .EXAMPLE
        Set-SAFileLogToolVersions -ToolVersions @{
            'PowerShell' = '7.5.4 Core'
            'WinRAR' = @{ Version = '7.13'; Path = 'C:\Program Files\WinRAR\rar.exe' }
            'MKVToolNix' = @{ Version = '96.0'; Path = 'C:\Program Files\MKVToolNix\mkvmerge.exe' }
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ToolVersions
    )
    
    foreach ($tool in $ToolVersions.GetEnumerator()) {
        $value = $tool.Value
        
        if ($value -is [hashtable]) {
            $script:SAFileLogState.ToolVersions[$tool.Key] = @{
                Version = $value.Version
                Path    = $value.Path
            }
        } else {
            $script:SAFileLogState.ToolVersions[$tool.Key] = @{
                Version = $value
                Path    = ''
            }
        }
    }
}

#endregion
