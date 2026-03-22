#Requires -Version 5.1
<#
.SYNOPSIS
    Email renderer for Stagearr output events
.DESCRIPTION
    Main email renderer that orchestrates HTML email generation:
    - State management (summary data, exceptions, log path)
    - Initialization and reset
    - Main assembly function (ConvertTo-SAEmailHtml)
    
    This is the public interface. HTML generation is delegated to:
    - EmailHelpers.ps1: Display formatting utilities and color palette
    - EmailSections.ps1: HTML section builders
    - EmailSubject.ps1: Subject line generation
    
    Per OUTPUT-STYLE-GUIDE: "Email is the post-run dashboard... consumed 
    asynchronously (often on a phone), so it should be compact and verdict-first."
    
    Depends on: EmailHelpers.ps1, EmailSections.ps1, EmailSubject.ps1
#>

#region Module State

$script:SAEmailState = @{
    Initialized = $false
    LogPath     = ''    # Path to filesystem log for reference
}

# Collected summary data (aggregated from events)
$script:SAEmailSummary = @{
    Name           = ''
    SourceName     = ''        # Original release/folder name (E2 enhancement)
    Label          = ''
    Subtitles      = @()
    MissingLangs   = @()
    ImportTarget   = ''
    ImportResult   = ''
    ImportMessage  = ''
    Result         = 'Success'  # Success, Warning, Failed, Skipped
    Duration       = ''
    Exceptions     = @()
    VideoCount     = 0
    VideoSize      = ''
    IsPassthrough  = $false
    FailurePhase   = ''        # Phase where failure occurred
    FailureError   = ''        # Error message for failure
    FailurePath    = ''        # Relevant path for failure context
    ReleaseInfo    = $null     # For subject template (ScreenSize, Source, etc.)
    TorrentHash    = ''        # For {hash4} placeholder
    OmdbData       = $null     # OMDb metadata for email enrichment (poster, ratings, genre)
}

#endregion

#region Initialization

function Initialize-SAEmailRenderer {
    <#
    .SYNOPSIS
        Initializes the email renderer.
    .DESCRIPTION
        Resets summary data and prepares for a new job.
        Called automatically by Initialize-SAOutputSystem.
    #>
    [CmdletBinding()]
    param()
    
    $script:SAEmailState = @{
        Initialized = $true
        LogPath     = ''
    }
    
    $script:SAEmailSummary = @{
        Name           = ''
        SourceName     = ''
        Label          = ''
        Subtitles      = @()
        MissingLangs   = @()
        ImportTarget   = ''
        ImportResult   = ''
        ImportMessage  = ''
        Result         = 'Success'
        Duration       = ''
        Exceptions     = @()
        VideoCount     = 0
        VideoSize      = ''
        IsPassthrough  = $false
        FailurePhase   = ''
        FailureError   = ''
        FailurePath    = ''
        ReleaseInfo    = $null
        TorrentHash    = ''
        OmdbData       = $null
    }
}

function Reset-SAEmailRenderer {
    <#
    .SYNOPSIS
        Resets email renderer state.
    #>
    [CmdletBinding()]
    param()
    
    Initialize-SAEmailRenderer
    $script:SAEmailState.Initialized = $false
}

function Set-SAEmailLogPath {
    <#
    .SYNOPSIS
        Sets the filesystem log path to include in email.
    .PARAMETER Path
        Path to the log file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    $script:SAEmailState.LogPath = $Path
}

#endregion

#region Summary Building

function Set-SAEmailSummary {
    <#
    .SYNOPSIS
        Sets email summary data directly.
    .DESCRIPTION
        Used by job processor to set final summary values.
    .PARAMETER Name
        Job/release friendly name (parsed title)
    .PARAMETER SourceName
        Original release/folder name (for reference)
    .PARAMETER Label
        Download label
    .PARAMETER Subtitles
        Array of subtitle language names present
    .PARAMETER MissingLangs
        Array of missing subtitle language names
    .PARAMETER ImportTarget
        Import target name (Radarr, Medusa, Passthrough, etc.)
    .PARAMETER ImportResult
        Import result (Imported, Skipped, Failed, Files staged)
    .PARAMETER ImportMessage
        Additional import message
    .PARAMETER Result
        Overall result: Success, Warning, Failed, Skipped
    .PARAMETER Duration
        Duration string
    .PARAMETER VideoCount
        Number of video files processed
    .PARAMETER VideoSize
        Total video size string
    .PARAMETER IsPassthrough
        Whether this is a passthrough job
    .PARAMETER FailurePhase
        Phase where failure occurred
    .PARAMETER FailureError
        Error message for failure
    .PARAMETER FailurePath
        Relevant path for failure context
    .PARAMETER ReleaseInfo
        Release info object from Get-SAReleaseInfo (ScreenSize, Source, ReleaseGroup, etc.)
    .PARAMETER TorrentHash
        Torrent hash for {hash4} placeholder in subject template
    .PARAMETER OmdbData
        OMDb metadata hashtable for email enrichment (poster, ratings, genre, IMDb link)
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Name,
        
        [Parameter()]
        [string]$SourceName,
        
        [Parameter()]
        [string]$Label,
        
        [Parameter()]
        [string[]]$Subtitles,
        
        [Parameter()]
        [string[]]$MissingLangs,
        
        [Parameter()]
        [string]$ImportTarget,
        
        [Parameter()]
        [string]$ImportResult,
        
        [Parameter()]
        [string]$ImportMessage,
        
        [Parameter()]
        [ValidateSet('Success', 'Warning', 'Failed', 'Skipped', 'Blocked')]
        [string]$Result,
        
        [Parameter()]
        [string]$Duration,
        
        [Parameter()]
        [int]$VideoCount,
        
        [Parameter()]
        [string]$VideoSize,
        
        [Parameter()]
        [switch]$IsPassthrough,
        
        [Parameter()]
        [string]$FailurePhase,
        
        [Parameter()]
        [string]$FailureError,
        
        [Parameter()]
        [string]$FailurePath,
        
        [Parameter()]
        [object]$ReleaseInfo,
        
        [Parameter()]
        [string]$TorrentHash,
        
        [Parameter()]
        [hashtable]$OmdbData
    )
    
    if ($PSBoundParameters.ContainsKey('Name')) {
        $script:SAEmailSummary.Name = $Name
    }
    if ($PSBoundParameters.ContainsKey('SourceName')) {
        $script:SAEmailSummary.SourceName = $SourceName
    }
    if ($PSBoundParameters.ContainsKey('Label')) {
        $script:SAEmailSummary.Label = $Label
    }
    if ($PSBoundParameters.ContainsKey('Subtitles')) {
        $script:SAEmailSummary.Subtitles = $Subtitles
    }
    if ($PSBoundParameters.ContainsKey('MissingLangs')) {
        $script:SAEmailSummary.MissingLangs = $MissingLangs
    }
    if ($PSBoundParameters.ContainsKey('ImportTarget')) {
        $script:SAEmailSummary.ImportTarget = $ImportTarget
    }
    if ($PSBoundParameters.ContainsKey('ImportResult')) {
        $script:SAEmailSummary.ImportResult = $ImportResult
    }
    if ($PSBoundParameters.ContainsKey('ImportMessage')) {
        $script:SAEmailSummary.ImportMessage = $ImportMessage
    }
    if ($PSBoundParameters.ContainsKey('Result')) {
        $script:SAEmailSummary.Result = $Result
    }
    if ($PSBoundParameters.ContainsKey('Duration')) {
        $script:SAEmailSummary.Duration = $Duration
    }
    if ($PSBoundParameters.ContainsKey('VideoCount')) {
        $script:SAEmailSummary.VideoCount = $VideoCount
    }
    if ($PSBoundParameters.ContainsKey('VideoSize')) {
        $script:SAEmailSummary.VideoSize = $VideoSize
    }
    if ($PSBoundParameters.ContainsKey('IsPassthrough')) {
        $script:SAEmailSummary.IsPassthrough = $IsPassthrough.IsPresent
    }
    if ($PSBoundParameters.ContainsKey('FailurePhase')) {
        $script:SAEmailSummary.FailurePhase = $FailurePhase
    }
    if ($PSBoundParameters.ContainsKey('FailureError')) {
        $script:SAEmailSummary.FailureError = $FailureError
    }
    if ($PSBoundParameters.ContainsKey('FailurePath')) {
        $script:SAEmailSummary.FailurePath = $FailurePath
    }
    if ($PSBoundParameters.ContainsKey('ReleaseInfo')) {
        $script:SAEmailSummary.ReleaseInfo = $ReleaseInfo
    }
    if ($PSBoundParameters.ContainsKey('TorrentHash')) {
        $script:SAEmailSummary.TorrentHash = $TorrentHash
    }
    if ($PSBoundParameters.ContainsKey('OmdbData')) {
        $script:SAEmailSummary.OmdbData = $OmdbData
    }
}

function Add-SAEmailException {
    <#
    .SYNOPSIS
        Adds an exception/warning to the email.
    .PARAMETER Message
        Exception message
    .PARAMETER Type
        Exception type: Warning, Error, Info
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('Warning', 'Error', 'Info')]
        [string]$Type = 'Warning'
    )
    
    $script:SAEmailSummary.Exceptions += [PSCustomObject]@{
        Message = $Message
        Type    = $Type
    }
}

#endregion

#region HTML Generation - Main Entry Point

function ConvertTo-SAEmailHtml {
    <#
    .SYNOPSIS
        Generates the complete email HTML.
    .DESCRIPTION
        Creates a compact, mobile-friendly email following the style guide.
        Uses dark theme with card-based design.
        
        Orchestrates HTML generation by delegating to:
        - Get-SAEmailHtmlDocument (from EmailSections.ps1) for structure
        - Uses email summary state for content
    .PARAMETER Title
        Email title (for HTML document)
    .OUTPUTS
        Complete HTML string
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$Title = 'Stagearr Notification'
    )
    
    # Build from summary data and events
    $summary = $script:SAEmailSummary
    $events = Get-SAEmailEvents
    
    # Fill in summary from job metadata if not set
    if ([string]::IsNullOrWhiteSpace($summary.Name)) {
        $meta = Get-SAJobMetadata
        $summary.Name = $meta.Name
        $summary.Label = $meta.Label
    }
    
    # Calculate duration if not set
    if ([string]::IsNullOrWhiteSpace($summary.Duration)) {
        $duration = Get-SAJobDuration
        $summary.Duration = Format-SADuration -Duration $duration
    }
    
    # Determine result from events if not explicitly set
    if ($summary.Result -eq 'Success') {
        $hasErrors = @($events | Where-Object { $_.Level -eq 'Error' }).Count -gt 0
        $hasWarnings = @($events | Where-Object { $_.Level -eq 'Warning' }).Count -gt 0
        
        if ($hasErrors) {
            $summary.Result = 'Failed'
        } elseif ($hasWarnings) {
            $summary.Result = 'Warning'
        }
    }
    
    # Build HTML using EmailSections module
    $html = Get-SAEmailHtmlDocument -Title $Title -Summary $summary -Events $events
    
    return $html
}

#endregion
