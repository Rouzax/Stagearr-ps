#Requires -Version 5.1
<#
.SYNOPSIS
    Event-based output system for Stagearr
.DESCRIPTION
    Implements the Output Contract from OUTPUT-STYLE-GUIDE.md:
    - Business logic emits events with structured data
    - Renderers (Console, FileLog, Email) decide how to display them
    - Single source of truth prevents channel drift
    
    This decouples "what happened" from "how to show it" and enables:
    - Consistent output across all channels
    - Easy addition of new renderers (Slack, Discord, etc.)
    - Testable output logic
    - Channel-specific formatting rules
#>

#region Module State

# Central event collection - all events go here
$script:SAOutputEvents = [System.Collections.Generic.List[PSCustomObject]]::new()

# Job metadata for context
$script:SAJobMetadata = @{
    Name        = ''
    Label       = ''
    StartTime   = $null
    SourcePath  = ''
    StagingPath = ''
}

# Renderer registration
$script:SARenderers = @{
    Console = $true
    FileLog = $true
    Email   = $true
}

# State tracking for batch operations
$script:SABatchState = @{
    CurrentPhase   = ''
    FileIndex      = 0
    FileCount      = 0
    LastHeartbeat  = $null
    HeartbeatInterval = 15  # seconds between heartbeat messages
}

# Polling state for rate limiting
$script:SAPollingState = @{
    LastStatus     = ''
    LastStatusTime = $null
    StatusCount    = 0
}

#endregion

#region Initialization and Reset

function Initialize-SAOutputSystem {
    <#
    .SYNOPSIS
        Initializes the output system for a new job.
    .DESCRIPTION
        Resets all state and prepares renderers for a new job run.
        Call this at the start of each job.
    .PARAMETER Name
        Job/release name for display.
    .PARAMETER Label
        Download label (TV, Movie, etc.).
    .PARAMETER SourcePath
        Path to source files.
    .PARAMETER StagingPath
        Path to staging folder.
    .PARAMETER LogFolder
        Folder for filesystem logs.
    .PARAMETER TorrentHash
        Torrent info hash (optional, for log header).
    .EXAMPLE
        Initialize-SAOutputSystem -Name "Movie.2024" -Label "Movie" -SourcePath "C:\Downloads\Movie" -LogFolder "C:\Logs"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Name = '',
        
        [Parameter()]
        [string]$Label = '',
        
        [Parameter()]
        [string]$SourcePath = '',
        
        [Parameter()]
        [string]$StagingPath = '',
        
        [Parameter()]
        [string]$LogFolder = '',
        
        [Parameter()]
        [string]$TorrentHash = '',

        [Parameter()]
        [switch]$VerboseMode
    )
    
    # Reset event collection
    $script:SAOutputEvents = [System.Collections.Generic.List[PSCustomObject]]::new()
    
    # Set job metadata
    $script:SAJobMetadata = @{
        Name        = $Name
        Label       = $Label
        StartTime   = Get-Date
        SourcePath  = $SourcePath
        StagingPath = $StagingPath
        TorrentHash = $TorrentHash
    }
    
    # Reset batch state
    $script:SABatchState = @{
        CurrentPhase      = ''
        FileIndex         = 0
        FileCount         = 0
        LastHeartbeat     = $null
        HeartbeatInterval = 15
    }
    
    # Reset polling state
    $script:SAPollingState = @{
        LastStatus     = ''
        LastStatusTime = $null
        StatusCount    = 0
    }
    
    # Initialize renderers
    Initialize-SAConsoleRenderer -VerboseMode:$VerboseMode
    Initialize-SAFileLogRenderer -LogFolder $LogFolder -JobName $Name
    Initialize-SAEmailRenderer
}

function Reset-SAOutputState {
    <#
    .SYNOPSIS
        Resets output system state between jobs.
    .DESCRIPTION
        Clears accumulated events and state. Call between jobs in worker mode
        to prevent memory leaks and cross-job contamination.
    #>
    [CmdletBinding()]
    param()
    
    $script:SAOutputEvents = [System.Collections.Generic.List[PSCustomObject]]::new()
    $script:SAJobMetadata = @{
        Name        = ''
        Label       = ''
        StartTime   = $null
        SourcePath  = ''
        StagingPath = ''
    }
    $script:SABatchState = @{
        CurrentPhase      = ''
        FileIndex         = 0
        FileCount         = 0
        LastHeartbeat     = $null
        HeartbeatInterval = 15
    }
    $script:SAPollingState = @{
        LastStatus     = ''
        LastStatusTime = $null
        StatusCount    = 0
    }
    
    # Note: Intentionally no verbose here - internal state reset is not useful for troubleshooting
}

function Set-SAFileLogConfig {
    <#
    .SYNOPSIS
        Configures the file log path after context is available.
    .DESCRIPTION
        Called after Initialize-SAContext to set the exact log file path
        based on context configuration. This supports the Phase 4 requirement
        to always have a log path available for early exit scenarios.
    .PARAMETER LogPath
        Full path to the log file.
    .PARAMETER ToolVersions
        Hashtable of tool names and versions to include in log header.
    .EXAMPLE
        Set-SAFileLogConfig -LogPath "C:\Logs\2024.01.15_14.30.45-Movie.log"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$LogPath = '',
        
        [Parameter()]
        [hashtable]$ToolVersions = $null
    )
    
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Set-SAFileLogPath -Path $LogPath
    }
    
    if ($null -ne $ToolVersions -and $ToolVersions.Count -gt 0) {
        Set-SAFileLogToolVersions -ToolVersions $ToolVersions
    }
}

function Get-SAJobMetadata {
    <#
    .SYNOPSIS
        Returns current job metadata.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    
    return $script:SAJobMetadata.Clone()
}

function Get-SAJobDuration {
    <#
    .SYNOPSIS
        Returns elapsed time since job start.
    #>
    [CmdletBinding()]
    [OutputType([TimeSpan])]
    param()
    
    if ($null -eq $script:SAJobMetadata.StartTime) {
        return [TimeSpan]::Zero
    }
    return (Get-Date) - $script:SAJobMetadata.StartTime
}

#endregion

#region Event Creation

function New-SAOutputEvent {
    <#
    .SYNOPSIS
        Creates a new output event object.
    .DESCRIPTION
        Factory function that creates a structured event matching the Output Contract.
        Events are the unit of communication between business logic and renderers.
    .PARAMETER Level
        Event severity: Verbose, Info, Success, Warning, Error
    .PARAMETER Phase
        High-level processing stage: RAR, Staging, Subtitles, Import, Cleanup, Passthrough
    .PARAMETER Label
        Short component tag (Radarr, OpenSubs, Medusa, etc.)
    .PARAMETER Text
        Human-readable message text
    .PARAMETER Details
        Additional key/value context (paths, counts, etc.) - shown in verbose/logs only
    .PARAMETER Duration
        How long the operation took (for outcomes)
    .PARAMETER IsHeader
        True if this is a section header
    .PARAMETER IsOutcome
        True if this should display a status marker (✓/!/✗)
    .PARAMETER BatchIndex
        Current file index in batch (1-based)
    .PARAMETER BatchTotal
        Total files in batch
    .PARAMETER ConsoleOnly
        Only show in console, not in logs/email
    .PARAMETER EmailInclude
        Explicitly include in email summary
    .PARAMETER EmailExclude
        Explicitly exclude from email summary
    .OUTPUTS
        PSCustomObject with event data
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Verbose', 'Info', 'Success', 'Warning', 'Error', 'Skip')]
        [string]$Level,
        
        [Parameter()]
        [ValidateSet('', 'Job', 'RAR', 'Staging', 'Subtitles', 'Import', 'Cleanup', 'Passthrough', 'Notification', 'Finalize')]
        [string]$Phase = '',
        
        [Parameter()]
        [string]$Label = '',
        
        [Parameter()]
        [string]$Text = '',
        
        [Parameter()]
        [hashtable]$Details = @{},
        
        [Parameter()]
        [Nullable[int]]$Duration = $null,
        
        [Parameter()]
        [switch]$IsHeader,
        
        [Parameter()]
        [switch]$IsOutcome,
        
        [Parameter()]
        [Nullable[int]]$BatchIndex = $null,
        
        [Parameter()]
        [Nullable[int]]$BatchTotal = $null,
        
        [Parameter()]
        [switch]$ConsoleOnly,
        
        [Parameter()]
        [switch]$EmailInclude,
        
        [Parameter()]
        [switch]$EmailExclude
    )
    
    return [PSCustomObject]@{
        Timestamp    = Get-Date
        Level        = $Level
        Phase        = $Phase
        Label        = $Label
        Text         = $Text
        Details      = $Details
        Duration     = $Duration
        IsHeader     = $IsHeader.IsPresent
        IsOutcome    = $IsOutcome.IsPresent
        BatchIndex   = $BatchIndex
        BatchTotal   = $BatchTotal
        ConsoleOnly  = $ConsoleOnly.IsPresent
        EmailInclude = $EmailInclude.IsPresent
        EmailExclude = $EmailExclude.IsPresent
    }
}

#endregion

#region Event Dispatch

function Write-SAEvent {
    <#
    .SYNOPSIS
        Main entry point for emitting output events.
    .DESCRIPTION
        Creates an event and dispatches it to all enabled renderers.
        This is the primary function business logic should call.
    .PARAMETER Level
        Event severity level.
    .PARAMETER Phase
        Processing phase.
    .PARAMETER Label
        Component label.
    .PARAMETER Text
        Message text.
    .PARAMETER Details
        Additional context.
    .PARAMETER Duration
        Operation duration in seconds.
    .PARAMETER IsHeader
        Section header flag.
    .PARAMETER IsOutcome
        Outcome marker flag.
    .PARAMETER BatchIndex
        Current batch index.
    .PARAMETER BatchTotal
        Total batch count.
    .PARAMETER ConsoleOnly
        Console-only flag.
    .PARAMETER EmailInclude
        Force email inclusion.
    .PARAMETER EmailExclude
        Force email exclusion.
    .EXAMPLE
        Write-SAEvent -Level Success -Label "Radarr" -Text "Imported" -Duration 45 -IsOutcome
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Verbose', 'Info', 'Success', 'Warning', 'Error', 'Skip')]
        [string]$Level,
        
        [Parameter()]
        [ValidateSet('', 'Job', 'RAR', 'Staging', 'Subtitles', 'Import', 'Cleanup', 'Passthrough', 'Notification', 'Finalize')]
        [string]$Phase = '',
        
        [Parameter()]
        [string]$Label = '',
        
        [Parameter()]
        [string]$Text = '',
        
        [Parameter()]
        [hashtable]$Details = @{},
        
        [Parameter()]
        [Nullable[int]]$Duration = $null,
        
        [Parameter()]
        [switch]$IsHeader,
        
        [Parameter()]
        [switch]$IsOutcome,
        
        [Parameter()]
        [Nullable[int]]$BatchIndex = $null,
        
        [Parameter()]
        [Nullable[int]]$BatchTotal = $null,
        
        [Parameter()]
        [switch]$ConsoleOnly,
        
        [Parameter()]
        [switch]$EmailInclude,
        
        [Parameter()]
        [switch]$EmailExclude
    )
    
    # Create the event
    $outputEvent = New-SAOutputEvent @PSBoundParameters
    
    # Store in central collection
    $script:SAOutputEvents.Add($outputEvent)
    
    # Dispatch to renderers
    if ($script:SARenderers.Console) {
        Write-SAConsoleEvent -Event $outputEvent
    }
    
    if ($script:SARenderers.FileLog -and -not $outputEvent.ConsoleOnly) {
        Write-SAFileLogEvent -Event $outputEvent
    }
    
    # Email renderer collects events but doesn't write immediately
    # (email is generated at job completion)
}

#endregion

#region Convenience Functions

function Write-SAPhaseHeader {
    <#
    .SYNOPSIS
        Emits a section header event.
    .DESCRIPTION
        Creates a visual section break in output.
        Per style guide: use nouns, not verbs.
    .PARAMETER Title
        Section title (e.g., "Staging", "Subtitles", "Import (Radarr)")
    .PARAMETER FileCount
        Optional file count for batch headers
    .EXAMPLE
        Write-SAPhaseHeader -Title "Staging"
        Write-SAPhaseHeader -Title "Staging" -FileCount 8
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        
        [Parameter()]
        [int]$FileCount = 0
    )
    
    # Build title with file count if batch
    $displayTitle = if ($FileCount -gt 1) { "$Title ($FileCount files)" } else { $Title }
    
    # Determine phase from title
    $phase = switch -Regex ($Title) {
        '^RAR'         { 'RAR' }
        '^Staging'     { 'Staging' }
        '^Subtitle'    { 'Subtitles' }
        '^Import'      { 'Import' }
        '^Cleanup'     { 'Cleanup' }
        '^Passthrough' { 'Passthrough' }
        '^Finalize'    { 'Finalize' }
        '^Job'         { 'Job' }
        default        { '' }
    }
    
    # Update batch state
    $script:SABatchState.CurrentPhase = $phase
    if ($FileCount -gt 0) {
        $script:SABatchState.FileCount = $FileCount
        $script:SABatchState.FileIndex = 0
    }
    
    Write-SAEvent -Level Info -Phase $phase -Text $displayTitle -IsHeader -EmailInclude
}

function Write-SAOutcome {
    <#
    .SYNOPSIS
        Emits an outcome event with status marker.
    .DESCRIPTION
        Outcomes get visual markers (✓/!/✗/↷) and are always shown.
        Use for completed operations, not in-progress updates.
    .PARAMETER Level
        Outcome level: Success, Warning, Error, Skip
    .PARAMETER Label
        Component label (Radarr, OpenSubs, etc.)
    .PARAMETER Text
        Outcome message
    .PARAMETER Duration
        Operation duration in seconds
    .PARAMETER Phase
        Processing phase
    .PARAMETER Details
        Additional context
    .PARAMETER Indent
        Indentation level for console hierarchy (0-3):
        - 0: Phase headers, phase summaries (no indent)
        - 1: File identifiers [n/N], top-level progress (2 spaces)
        - 2: File details, nested info (6 spaces)
    .PARAMETER RawIndent
        Raw indent string (overrides Indent level). Used for batch detail alignment.
    .PARAMETER ConsoleOnly
        Only show in console (for batch per-file outcomes)
    .PARAMETER EmailInclude
        Force email inclusion
    .EXAMPLE
        Write-SAOutcome -Level Success -Label "Radarr" -Text "Imported" -Duration 45
    .EXAMPLE
        Write-SAOutcome -Level Success -Label "Extracted" -Text "Dutch" -Indent 1
    .EXAMPLE
        Write-SAOutcome -Level Skip -Label "Import" -Text "Passthrough mode (no import configured)"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Warning', 'Error', 'Skip')]
        [string]$Level,
        
        [Parameter()]
        [string]$Label = '',
        
        [Parameter()]
        [string]$Text = '',
        
        [Parameter()]
        [Nullable[int]]$Duration = $null,
        
        [Parameter()]
        [string]$Phase = '',
        
        [Parameter()]
        [hashtable]$Details = @{},
        
        [Parameter()]
        [ValidateRange(0, 3)]
        [int]$Indent = 0,
        
        [Parameter()]
        [string]$RawIndent = '',
        
        [Parameter()]
        [switch]$ConsoleOnly,
        
        [Parameter()]
        [switch]$EmailInclude
    )
    
    # Use current phase if not specified
    if ([string]::IsNullOrWhiteSpace($Phase)) {
        $Phase = $script:SABatchState.CurrentPhase
    }
    
    # Store indent in details for renderer
    $eventDetails = $Details.Clone()
    if (-not [string]::IsNullOrEmpty($RawIndent)) {
        $eventDetails['_RawIndent'] = $RawIndent
    } else {
        $eventDetails['_Indent'] = $Indent
    }
    
    Write-SAEvent -Level $Level -Phase $Phase -Label $Label -Text $Text `
        -Duration $Duration -Details $eventDetails -IsOutcome -ConsoleOnly:$ConsoleOnly -EmailInclude:$EmailInclude
}

function Write-SAProgress {
    <#
    .SYNOPSIS
        Emits a progress/info event (no marker).
    .DESCRIPTION
        Progress events show what's happening but don't indicate completion.
        Use for "starting X", "processing Y", status updates.
    .PARAMETER Label
        Component label
    .PARAMETER Text
        Progress message
    .PARAMETER Phase
        Processing phase
    .PARAMETER Details
        Additional context
    .PARAMETER Indent
        Indentation level for console hierarchy (0-3):
        - 0: Phase headers, phase summaries (no indent)
        - 1: File identifiers [n/N], top-level progress (2 spaces)
        - 2: File details, nested info (6 spaces)
    .PARAMETER RawIndent
        Raw indent string (overrides Indent level). Used for batch detail alignment.
    .PARAMETER ConsoleOnly
        Only show in console
    .PARAMETER EmailExclude
        Exclude from email
    .EXAMPLE
        Write-SAProgress -Label "Source" -Text "movie.mkv (4.2 GB)" -Indent 1
    .EXAMPLE
        Write-SAProgress -Label "Tracks" -Text "1 video, 2 audio" -Indent 2
    .EXAMPLE
        Write-SAProgress -Label "Source" -Text "S01E01.mkv (847 MB) [1/8]" -Indent 1 # Batch suffix format
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Label = '',
        
        [Parameter()]
        [string]$Text = '',
        
        [Parameter()]
        [string]$Phase = '',
        
        [Parameter()]
        [hashtable]$Details = @{},
        
        [Parameter()]
        [ValidateRange(0, 3)]
        [int]$Indent = 1,
        
        [Parameter()]
        [string]$RawIndent = '',
        
        [Parameter()]
        [switch]$ConsoleOnly,
        
        [Parameter()]
        [switch]$EmailExclude
    )
    
    # Use current phase if not specified
    if ([string]::IsNullOrWhiteSpace($Phase)) {
        $Phase = $script:SABatchState.CurrentPhase
    }
    
    # Store indent in details for renderer
    $eventDetails = if ($null -eq $Details) { @{} } else { $Details.Clone() }
    if (-not [string]::IsNullOrEmpty($RawIndent)) {
        $eventDetails['_RawIndent'] = $RawIndent
    } else {
        $eventDetails['_Indent'] = $Indent
    }
    
    Write-SAEvent -Level Info -Phase $Phase -Label $Label -Text $Text `
        -Details $eventDetails -ConsoleOnly:$ConsoleOnly -EmailExclude:$EmailExclude
}

function Write-SAVerbose {
    <#
    .SYNOPSIS
        Emits a verbose-level event.
    .DESCRIPTION
        Verbose events appear in:
        - Console when -Verbose is used (via console renderer)
        - Filesystem logs (always, for forensic analysis)
        
        Use for technical details, debugging info, "how/why" context.
    .PARAMETER Text
        Verbose message
    .PARAMETER Label
        Optional component label
    .PARAMETER Phase
        Processing phase
    .EXAMPLE
        Write-SAVerbose -Text "OpenSubtitles hash: abc123def"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        
        [Parameter()]
        [string]$Label = '',
        
        [Parameter()]
        [string]$Phase = ''
    )
    
    if ([string]::IsNullOrWhiteSpace($Phase)) {
        $Phase = $script:SABatchState.CurrentPhase
    }
    
    # Emit to event system (dispatches to console and file log)
    # Console renderer calls Write-Verbose for verbose events
    # File log renderer captures all events including verbose
    Write-SAEvent -Level Verbose -Phase $Phase -Label $Label -Text $Text
}

function Write-SAPollingStatus {
    <#
    .SYNOPSIS
        Emits a polling status with rate limiting.
    .DESCRIPTION
        Implements the heartbeat pattern from the style guide:
        - Show immediately on state change
        - Show heartbeat every ~15 seconds if state unchanged
        - Always include elapsed time
    .PARAMETER Status
        Current status text
    .PARAMETER ElapsedSeconds
        Seconds since operation started
    .PARAMETER Label
        Component label
    .PARAMETER ForceShow
        Bypass rate limiting
    .EXAMPLE
        Write-SAPollingStatus -Status "Started" -ElapsedSeconds 5 -Label "Radarr"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Status,
        
        [Parameter(Mandatory = $true)]
        [int]$ElapsedSeconds,
        
        [Parameter()]
        [string]$Label = '',
        
        [Parameter()]
        [switch]$ForceShow
    )
    
    # Skip if status is empty/null - nothing useful to display
    if ([string]::IsNullOrWhiteSpace($Status)) {
        return
    }
    
    $now = Get-Date
    $shouldShow = $false
    
    # Always show on state change
    if ($Status -ne $script:SAPollingState.LastStatus) {
        $shouldShow = $true
        $script:SAPollingState.LastStatus = $Status
        $script:SAPollingState.StatusCount = 1
    } else {
        $script:SAPollingState.StatusCount++
        
        # Show heartbeat if enough time passed
        if ($null -eq $script:SAPollingState.LastStatusTime) {
            $shouldShow = $true
        } else {
            $elapsed = ($now - $script:SAPollingState.LastStatusTime).TotalSeconds
            if ($elapsed -ge $script:SABatchState.HeartbeatInterval) {
                $shouldShow = $true
            }
        }
    }
    
    if ($ForceShow) { $shouldShow = $true }
    
    if ($shouldShow) {
        $script:SAPollingState.LastStatusTime = $now
        
        # Format: "Status: Started... (5s)" or "Status: Still running... (35s)"
        $displayStatus = if ($script:SAPollingState.StatusCount -gt 2) {
            "Still running... ($($ElapsedSeconds)s)"
        } else {
            "$Status ($($ElapsedSeconds)s)"
        }
        
        Write-SAEvent -Level Info -Phase 'Import' -Label "Status" -Text $displayStatus `
            -Details @{ '_Indent' = 2 } -ConsoleOnly
    }
}

#endregion

#region Event Access

function Get-SAOutputEvents {
    <#
    .SYNOPSIS
        Returns all collected events.
    .DESCRIPTION
        Used by renderers and for testing.
    .PARAMETER Phase
        Filter by phase
    .PARAMETER Level
        Filter by level
    .PARAMETER IncludeVerbose
        Include verbose-level events
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter()]
        [string]$Phase = '',
        
        [Parameter()]
        [string]$Level = '',
        
        [Parameter()]
        [switch]$IncludeVerbose
    )
    
    $events = $script:SAOutputEvents
    
    if (-not [string]::IsNullOrWhiteSpace($Phase)) {
        $events = $events | Where-Object { $_.Phase -eq $Phase }
    }
    
    if (-not [string]::IsNullOrWhiteSpace($Level)) {
        $events = $events | Where-Object { $_.Level -eq $Level }
    }
    
    if (-not $IncludeVerbose) {
        $events = $events | Where-Object { $_.Level -ne 'Verbose' }
    }
    
    return @($events)
}

function Get-SAEmailEvents {
    <#
    .SYNOPSIS
        Returns events suitable for email summary.
    .DESCRIPTION
        Filters events according to email rules:
        - Include headers
        - Include outcomes (Success/Warning/Error)
        - Include explicitly marked EmailInclude
        - Exclude verbose, console-only, and EmailExclude
        - Summarize batch operations
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()
    
    $events = $script:SAOutputEvents | Where-Object {
        # Exclude verbose
        if ($_.Level -eq 'Verbose') { return $false }
        
        # Exclude console-only
        if ($_.ConsoleOnly) { return $false }
        
        # Exclude explicitly excluded
        if ($_.EmailExclude) { return $false }
        
        # Include explicitly included
        if ($_.EmailInclude) { return $true }
        
        # Include headers
        if ($_.IsHeader) { return $true }
        
        # Include outcomes
        if ($_.IsOutcome) { return $true }
        
        # Include warnings and errors
        if ($_.Level -in @('Warning', 'Error')) { return $true }
        
        # Default: exclude
        return $false
    }
    
    return @($events)
}

#endregion
